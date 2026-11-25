import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'phase2.dart';
import 'repositories.dart';

const _uuid = Uuid();

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

String hostOf(String? url) {
  final u = Uri.tryParse(url ?? '');
  var h = (u?.host ?? '').toLowerCase();
  if (h.startsWith('www.')) h = h.substring(4);
  return h;
}

/// Duplicate keys of a row. NOTE: sharing an email never makes two accounts duplicates
/// (spec: accounts are never merged because of a shared email).
List<String> dupKeys(String table, Map<String, Object?> row) {
  final n = normalizeText;
  switch (table) {
    case 'platforms':
      final h = hostOf(_s(row['base_url']));
      return [if (_s(row['name']) != null) 'n:${n(row['name'] as String).trim()}', if (h.isNotEmpty) 'h:$h'];
    case 'emails':
      return [if (_s(row['address']) != null) 'e:${normalizeEmail(row['address'] as String)}'];
    case 'accounts':
      final p = row['platform_id'];
      return [
        if (_s(row['username']) != null) 'u:$p|${n(row['username'] as String).trim()}',
        if (_s(row['external_id']) != null) 'x:$p|${row['external_id']}',
      ];
    case 'projects':
      return [if (_s(row['name']) != null) 'n:${n(row['name'] as String).trim()}'];
    case 'resources':
      return [if (_s(row['name']) != null) 'r:${row['type']}|${n(row['name'] as String).trim()}|${row['platform_id']}'];
  }
  return const [];
}

const dedupeTables = {
  'platforms': 'platform', 'emails': 'email', 'accounts': 'account',
  'projects': 'project', 'resources': 'resource',
};

class DupGroup {
  DupGroup(this.entity, this.ids, this.labels, this.reason);
  final String entity, reason;
  final List<String> ids, labels;
}

class _Ref {
  const _Ref(this.table, this.entity, this.col, [this.scope = const []]);
  final String table, entity, col;
  final List<String> scope; // other unique-key columns of a join table
}

const _refs = {
  'platform': [_Ref('accounts', 'account', 'platform_id'), _Ref('resources', 'resource', 'platform_id')],
  'email': [
    _Ref('account_emails', 'account_email', 'email_id', ['account_id', 'role']),
    _Ref('identity_emails', 'identity_email', 'email_id', ['identity_id']),
  ],
  'account': [
    _Ref('account_emails', 'account_email', 'account_id', ['email_id', 'role']),
    _Ref('project_accounts', 'project_account', 'account_id', ['project_id', 'role']),
    _Ref('resources', 'resource', 'managing_account_id'),
  ],
  'project': [
    _Ref('project_accounts', 'project_account', 'project_id', ['account_id', 'role']),
    _Ref('project_resources', 'project_resource', 'project_id', ['resource_id']),
  ],
  'resource': [_Ref('project_resources', 'project_resource', 'resource_id', ['project_id'])],
};

extension AtlasDedupe on AtlasRepo {
  TableInfo _tbl(String t) => db.allTables.firstWhere((x) => x.actualTableName == t);

  Future<List<Map<String, Object?>>> _all(String table, {bool live = true}) async {
    final r = await db.customSelect(
        'SELECT * FROM $table${live ? ' WHERE deleted_at IS NULL' : ''}',
        readsFrom: {_tbl(table)}).get();
    return [for (final x in r) Map<String, Object?>.from(x.data)];
  }

  String _label(String table, Map<String, Object?> r) => switch (table) {
        'emails' => '${r['address']}',
        'accounts' => '${r['display_name']}${r['username'] == null ? '' : ' (${r['username']})'}',
        _ => '${r['name']}',
      };

  /// Scans live data for probable duplicates. Never changes anything.
  Future<List<DupGroup>> findDuplicates() async {
    final out = <DupGroup>[];
    for (final e in dedupeTables.entries) {
      final rows = await _all(e.key);
      final byKey = <String, List<Map<String, Object?>>>{};
      for (final r in rows) {
        for (final k in dupKeys(e.key, r)) {
          byKey.putIfAbsent(k, () => []).add(r);
        }
      }
      final seen = <String>{};
      for (final g in byKey.entries) {
        if (g.value.length < 2) continue;
        final ids = [for (final r in g.value) r['id'] as String]..sort();
        if (!seen.add(ids.join('|'))) continue;
        out.add(DupGroup(e.value, ids, [for (final r in g.value) _label(e.key, r)], g.key));
      }
    }
    return out;
  }

  /// Merges [dropId] into [keepId] (only ever called after explicit user confirmation).
  /// Re-points every relation, tombstones the dropped row. One batch => undoBatch reverts it.
  Future<String> mergeEntities(String entity, String keepId, String dropId) async {
    if (keepId == dropId) throw ArgumentError('same id');
    final table = entityTables[entity];
    if (table == null || !_refs.containsKey(entity)) throw ArgumentError('cannot merge $entity');
    final batch = _uuid.v4();
    await db.transaction(() async {
      if (await rowOf(entity, keepId) == null || await rowOf(entity, dropId) == null) {
        throw StateError('row missing');
      }
      if (entity == 'platform') {
        final c = await db.customSelect(
            'SELECT 1 FROM accounts a1 JOIN accounts a2 ON a2.external_id = a1.external_id '
            'WHERE a1.platform_id = ? AND a2.platform_id = ? AND a1.external_id IS NOT NULL',
            variables: [Variable<String>(dropId), Variable<String>(keepId)],
            readsFrom: {db.accounts}).get();
        if (c.isNotEmpty) throw StateError('accounts with the same external id exist on both platforms');
      }
      for (final ref in _refs[entity]!) {
        final rows = await db.customSelect(
            'SELECT * FROM ${ref.table} WHERE ${ref.col} = ? AND deleted_at IS NULL',
            variables: [Variable<String>(dropId)], readsFrom: {_tbl(ref.table)}).get();
        for (final row in rows) {
          final id = row.read<String>('id');
          if (ref.scope.isEmpty) {
            await updateFields(ref.entity, id, {ref.col: keepId}, batch: batch);
            continue;
          }
          final where = [for (final c in ref.scope) '$c = ?', '${ref.col} = ?', 'id <> ?'].join(' AND ');
          final found = await db.customSelect('SELECT id, deleted_at FROM ${ref.table} WHERE $where',
              variables: [
                for (final c in ref.scope) Variable<String>(row.read<String>(c)),
                Variable<String>(keepId), Variable<String>(id),
              ], readsFrom: {_tbl(ref.table)}).get();
          if (found.isEmpty) {
            await updateFields(ref.entity, id, {ref.col: keepId}, batch: batch);
          } else {
            if (found.first.data['deleted_at'] != null) {
              await restore(ref.entity, found.first.read<String>('id'), batch: batch);
            }
            await softDelete(ref.entity, id, batch: batch);
          }
        }
      }
      for (final poly in const [('notes', 'note'), ('attachments', 'attachment')]) {
        final rows = await db.customSelect(
            'SELECT id FROM ${poly.$1} WHERE owner_type = ? AND owner_id = ? AND deleted_at IS NULL',
            variables: [Variable<String>(entity), Variable<String>(dropId)],
            readsFrom: {_tbl(poly.$1)}).get();
        for (final r in rows) {
          await updateFields(poly.$2, r.read<String>('id'), {'owner_id': keepId}, batch: batch);
        }
      }
      for (final side in const ['from', 'to']) {
        final rows = await db.customSelect(
            'SELECT id FROM connections WHERE ${side}_type = ? AND ${side}_id = ? AND deleted_at IS NULL',
            variables: [Variable<String>(entity), Variable<String>(dropId)],
            readsFrom: {db.connections}).get();
        for (final r in rows) {
          await updateFields('connection', r.read<String>('id'), {'${side}_id': keepId}, batch: batch);
        }
      }
      await softDelete(entity, dropId, batch: batch);
    });
    return batch;
  }
}
