import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'dedupe.dart';
import 'exporter.dart';
import 'phase2.dart';
import 'repositories.dart';

const _uuid = Uuid();

enum ImportStatus { add, same, changed, duplicate, problem }
enum Decision { add, skip, replace, merge }

class ImportItem {
  ImportItem(this.table, this.row, this.status, this.decision, {this.matchId, this.note, this.label});
  final String table;
  final Map<String, Object?> row;
  ImportStatus status;
  Decision decision;
  String? matchId, note, label;
  String get id => row['id'] as String;
}

class ImportPlan {
  ImportPlan(this.source);
  final String source;
  final items = <ImportItem>[];
  final warnings = <String>[];
  int count(ImportStatus s) => items.where((i) => i.status == s).length;
}

class ImportResult {
  ImportResult(this.batchId);
  final String batchId;
  int added = 0, replaced = 0, merged = 0, skipped = 0, alreadyThere = 0;
  final errors = <String>[];
}

/// Fields each CSV target understands (key, required).
const csvFields = {
  'accounts': [('platform', true), ('name', false), ('username', false), ('url', false),
    ('email', false), ('identity', false), ('external_id', false), ('notes', false)],
  'platforms': [('name', true), ('url', false), ('category', false)],
  'emails': [('address', true), ('label', false)],
  'projects': [('name', true), ('description', false), ('category', false), ('status', false)],
  'resources': [('type', false), ('name', true), ('platform', false), ('url', false), ('region', false)],
};

const _aliases = {
  'platform': ['platform', 'site', 'service', 'website', 'الموقع', 'المنصة', 'الخدمة'],
  'name': ['name', 'account', 'account name', 'display name', 'title', 'الاسم', 'اسم الحساب'],
  'username': ['username', 'user', 'login', 'user name', 'اسم المستخدم', 'المستخدم'],
  'url': ['url', 'link', 'profile', 'profile url', 'base_url', 'الرابط', 'رابط الحساب'],
  'email': ['email', 'e-mail', 'mail', 'emails', 'البريد', 'الايميل', 'البريد الالكتروني'],
  'address': ['address', 'email', 'e-mail', 'mail', 'البريد', 'عنوان البريد'],
  'identity': ['identity', 'الهوية'],
  'external_id': ['external_id', 'external id', 'id', 'المعرف'],
  'notes': ['notes', 'note', 'ملاحظات', 'ملاحظة'],
  'category': ['category', 'التصنيف'], 'label': ['label', 'الوسم'],
  'description': ['description', 'الوصف'], 'status': ['status', 'الحالة'],
  'type': ['type', 'النوع'], 'region': ['region', 'المنطقة'],
};

/// Suggests header -> field mapping by (Arabic-normalised) header names.
Map<String, int> guessMapping(String entity, List<String> headers) {
  final norm = [for (final h in headers) normalizeText(h).trim()];
  final out = <String, int>{};
  for (final f in csvFields[entity] ?? const <(String, bool)>[]) {
    final al = [for (final a in _aliases[f.$1] ?? [f.$1]) normalizeText(a).trim()];
    final i = norm.indexWhere(al.contains);
    if (i >= 0 && !out.values.contains(i)) out[f.$1] = i;
  }
  return out;
}

const _uniq = {
  'identity_emails': ['identity_id', 'email_id'],
  'account_emails': ['account_id', 'email_id', 'role'],
  'project_accounts': ['project_id', 'account_id', 'role'],
  'project_resources': ['project_id', 'resource_id'],
  'custom_field_values': ['def_id', 'entity_id'],
};
const _fk = {
  'accounts': {'platform_id': 'platforms', 'identity_id': 'identities'},
  'identity_emails': {'identity_id': 'identities', 'email_id': 'emails'},
  'account_emails': {'account_id': 'accounts', 'email_id': 'emails'},
  'project_accounts': {'project_id': 'projects', 'account_id': 'accounts'},
  'project_resources': {'project_id': 'projects', 'resource_id': 'resources'},
  'resources': {'platform_id': 'platforms', 'managing_account_id': 'accounts'},
  'custom_field_values': {'def_id': 'custom_field_defs'},
};
final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+$');
int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
const _entityOfTable = {
  'platforms': 'platform', 'identities': 'identity', 'emails': 'email', 'accounts': 'account',
  'projects': 'project', 'resources': 'resource', 'identity_emails': 'identity_email',
  'account_emails': 'account_email', 'project_accounts': 'project_account',
  'project_resources': 'project_resource', 'connections': 'connection', 'notes': 'note',
  'attachments': 'attachment', 'custom_field_defs': 'custom_field_def',
  'custom_field_values': 'custom_field_value',
};

extension AtlasImport on AtlasRepo {
  Set<String> _colsOf(String table) =>
      db.allTables.firstWhere((x) => x.actualTableName == table).$columns.map((c) => c.name).toSet();

  // ------------------------------------------------------------ JSON backup
  Future<ImportPlan> planBackup(String text, {String source = 'backup'}) async {
    Object? m;
    try { m = jsonDecode(text); } catch (_) { throw const FormatException('not valid JSON'); }
    if (m is! Map || m['format'] != backupFormat) throw const FormatException('not an Account Atlas backup');
    final v = m['version'];
    if (v is! num || v > backupVersion) throw const FormatException('unsupported backup version');
    final tables = m['tables'];
    if (tables is! Map) throw const FormatException('missing tables');
    final counts = m['counts'];
    final plan = ImportPlan(source);
    for (final t in backupTables) {
      final rows = tables[t];
      if (rows == null) continue;
      if (rows is! List) throw FormatException('table $t malformed');
      if (counts is Map && counts[t] != null && counts[t] != rows.length) {
        throw FormatException('integrity check failed: row count of $t differs from manifest');
      }
      final cols = _colsOf(t);
      final existing = {for (final r in await dumpTable(t)) r['id'] as String: r};
      final byKey = <String, String>{};
      if (dedupeTables.containsKey(t)) {
        for (final r in existing.values) {
          if (r['deleted_at'] != null) continue;
          for (final k in dupKeys(t, r)) { byKey.putIfAbsent(k, () => r['id'] as String); }
        }
      }
      var dropped = false;
      for (final raw in rows) {
        if (raw is! Map) throw FormatException('table $t has a non-object row');
        final row = <String, Object?>{};
        raw.forEach((k, val) {
          if (cols.contains(k)) { row[k as String] = val; } else { dropped = true; }
        });
        final id = row['id'];
        if (id is! String || id.isEmpty) throw FormatException('table $t has a row without id');
        final ex = existing[id];
        final label = _lbl(t, row);
        if (ex == null) {
          final dups = row['deleted_at'] != null ? <String>[] : [for (final k in dupKeys(t, row)) if (byKey[k] != null) byKey[k]!];
          if (dups.isNotEmpty) {
            plan.items.add(ImportItem(t, row, ImportStatus.duplicate, Decision.skip,
                matchId: dups.first, label: label, note: 'duplicate of an existing item'));
          } else {
            plan.items.add(ImportItem(t, row, ImportStatus.add, Decision.add, label: label));
          }
        } else if (_same(ex, row)) {
          plan.items.add(ImportItem(t, row, ImportStatus.same, Decision.skip, label: label));
        } else {
          plan.items.add(ImportItem(t, row, ImportStatus.changed, Decision.skip, label: label,
              note: 'differs from your copy (kept yours by default)'));
        }
      }
      if (dropped) plan.warnings.add('table $t: unknown columns ignored (backup from a newer app?)');
    }
    return plan;
  }

  bool _same(Map<String, Object?> a, Map<String, Object?> b) {
    for (final k in b.keys) {
      if (k == 'updated_at' || k == 'hlc') continue;
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  String _lbl(String t, Map<String, Object?> r) {
    final v = r['name'] ?? r['display_name'] ?? r['address'] ?? r['body'] ?? r['file_name'] ?? r['kind'] ?? r['role'] ?? r['id'];
    return '$v';
  }

  // ------------------------------------------------------------ CSV
  Future<ImportPlan> planCsv(String entity, List<List<String>> table, Map<String, int> mapping,
      {String source = 'file.csv'}) async {
    final fields = csvFields[entity];
    if (fields == null) throw ArgumentError('no CSV import for $entity');
    final plan = ImportPlan(source);
    for (final f in fields) {
      if (f.$2 && !mapping.containsKey(f.$1)) {
        throw FormatException('required field "${f.$1}" is not mapped');
      }
    }
    String get(List<String> r, String f) {
      final i = mapping[f];
      return i == null || i >= r.length ? '' : r[i].trim();
    }
    Map<String, Object?> base() => {
          'id': _uuid.v7(), 'created_at': _now(), 'updated_at': _now(),
          'origin': 'imported', 'origin_ref': 'csv:$source',
        };
    String n(String s) => normalizeText(s).trim();

    // existing lookups
    final plats = <String, String>{}, mails = <String, String>{}, idents = <String, String>{};
    for (final r in await dumpLive('platforms')) { plats.putIfAbsent(n(r['name'] as String), () => r['id'] as String); }
    for (final r in await dumpLive('emails')) { mails.putIfAbsent(normalizeEmail(r['address'] as String), () => r['id'] as String); }
    for (final r in await dumpLive('identities')) { idents.putIfAbsent(n(r['name'] as String), () => r['id'] as String); }
    final seen = <String, String>{}; // dup key -> id (existing or planned)
    if (dedupeTables.containsKey(entity)) {
      for (final r in await dumpLive(entity)) {
        for (final k in dupKeys(entity, r)) { seen.putIfAbsent(k, () => r['id'] as String); }
      }
    }

    String platformId(String name) {
      final k = n(name);
      return plats.putIfAbsent(k, () {
        final row = {...base(), 'name': name, 'is_custom': 1, 'api_capability': 'none'};
        plan.items.add(ImportItem('platforms', row, ImportStatus.add, Decision.add, label: name, note: 'new platform'));
        return row['id'] as String;
      });
    }
    String emailId(String addr) {
      final k = normalizeEmail(addr);
      return mails.putIfAbsent(k, () {
        final row = {...base(), 'address': addr, 'address_normalized': k};
        plan.items.add(ImportItem('emails', row, ImportStatus.add, Decision.add, label: addr, note: 'new email'));
        return row['id'] as String;
      });
    }
    String identityId(String name) => idents.putIfAbsent(n(name), () {
          final row = {...base(), 'name': name};
          plan.items.add(ImportItem('identities', row, ImportStatus.add, Decision.add, label: name, note: 'new identity'));
          return row['id'] as String;
        });

    var line = 1;
    for (final r in table.skip(1)) {
      line++;
      if (r.every((c) => c.trim().isEmpty)) continue;
      void problem(String why) => plan.items.add(ImportItem(
          _tableOf(entity), {...base()}, ImportStatus.problem, Decision.skip,
          label: 'line $line', note: why));
      Map<String, Object?>? row;
      switch (entity) {
        case 'platforms':
          final name = get(r, 'name');
          if (name.isEmpty) { problem('missing name'); continue; }
          row = {...base(), 'name': name, 'base_url': _nz(get(r, 'url')), 'category': _nz(get(r, 'category')),
            'is_custom': 1, 'api_capability': 'none'};
        case 'emails':
          final a = get(r, 'address');
          if (!_emailRe.hasMatch(a)) { problem('not an email address'); continue; }
          row = {...base(), 'address': a, 'address_normalized': normalizeEmail(a), 'label': _nz(get(r, 'label'))};
        case 'projects':
          final name = get(r, 'name');
          if (name.isEmpty) { problem('missing name'); continue; }
          row = {...base(), 'name': name, 'description': _nz(get(r, 'description')),
            'category': _nz(get(r, 'category')), 'status': _nz(get(r, 'status')) ?? 'active'};
        case 'resources':
          final name = get(r, 'name');
          if (name.isEmpty) { problem('missing name'); continue; }
          final t = get(r, 'type').toLowerCase();
          final pn = get(r, 'platform');
          row = {...base(), 'name': name,
            'type': const ['database', 'hosting', 'domain', 'storage', 'api', 'subscription', 'custom'].contains(t) ? t : 'custom',
            'platform_id': pn.isEmpty ? null : platformId(pn),
            'url': _nz(get(r, 'url')), 'region': _nz(get(r, 'region'))};
        case 'accounts':
          final pn = get(r, 'platform');
          final user = get(r, 'username');
          final name = get(r, 'name').isNotEmpty ? get(r, 'name') : user;
          if (pn.isEmpty) { problem('missing platform'); continue; }
          if (name.isEmpty) { problem('missing name and username'); continue; }
          final ident = get(r, 'identity');
          row = {...base(), 'platform_id': platformId(pn), 'display_name': name,
            'username': _nz(user), 'profile_url': _nz(get(r, 'url')),
            'external_id': _nz(get(r, 'external_id')),
            'identity_id': ident.isEmpty ? null : identityId(ident),
            'connection_status': 'none'};
      }
      if (row == null) continue;
      final t = _tableOf(entity);
      final keys = dupKeys(t, row);
      final hit = keys.map((k) => seen[k]).whereType<String>().firstOrNull;
      final item = ImportItem(t, row, hit == null ? ImportStatus.add : ImportStatus.duplicate,
          hit == null ? Decision.add : Decision.skip, matchId: hit, label: _lbl(t, row),
          note: hit == null ? null : 'probable duplicate (line $line)');
      plan.items.add(item);
      if (hit == null) { for (final k in keys) { seen[k] = item.id; } }
      if (entity == 'accounts' && hit == null) {
        final id = item.id;
        for (final addr in get(r, 'email').split(RegExp(r'[;,|\s]+')).where((s) => s.isNotEmpty)) {
          if (!_emailRe.hasMatch(addr)) { plan.warnings.add('line $line: "$addr" is not an email, ignored'); continue; }
          plan.items.add(ImportItem('account_emails',
              {...base(), 'account_id': id, 'email_id': emailId(addr), 'role': 'login'},
              ImportStatus.add, Decision.add, label: addr));
        }
        final notes = get(r, 'notes');
        if (notes.isNotEmpty) {
          plan.items.add(ImportItem('notes', {...base(), 'owner_type': 'account', 'owner_id': id, 'body': notes},
              ImportStatus.add, Decision.add, label: notes));
        }
      }
    }
    return plan;
  }

  String? _nz(String s) => s.isEmpty ? null : s;
  String _tableOf(String entity) => entity; // csv targets are already table names

  Future<List<Map<String, Object?>>> dumpLive(String table) async =>
      [for (final r in await dumpTable(table)) if (r['deleted_at'] == null) r];

  // ------------------------------------------------------------ apply
  /// All-or-nothing: one transaction, foreign-key check at the end, every row logged under
  /// one batch id (=> [undoBatch] reverts the whole import).
  Future<ImportResult> applyImport(ImportPlan plan) async {
    final res = ImportResult(_uuid.v4());
    final known = <String, Set<String>>{};
    Future<bool> exists(String table, String id) async {
      known[table] ??= {
        for (final r in await db.customSelect('SELECT id FROM $table',
            readsFrom: {db.allTables.firstWhere((x) => x.actualTableName == table)}).get())
          r.read<String>('id')
      };
      return known[table]!.contains(id);
    }
    final order = {for (var i = 0; i < backupTables.length; i++) backupTables[i]: i};
    final items = [...plan.items.where((i) => order.containsKey(i.table))]
      ..sort((a, b) => order[a.table]!.compareTo(order[b.table]!));
    final remap = {
      for (final i in items) if (i.decision == Decision.merge && i.matchId != null) i.id: i.matchId!
    };
    final skippedIds = <String>{};

    await db.transaction(() async {
      for (final it in items) {
        final entity = _entityOfTable[it.table]!;
        if (it.status == ImportStatus.same) { res.alreadyThere++; continue; }
        if (it.decision == Decision.skip) {
          if (it.status != ImportStatus.changed) skippedIds.add(it.id);
          res.skipped++;
          continue;
        }
        if (it.decision == Decision.merge) { res.merged++; continue; }
        final cols = _colsOf(it.table);
        final row = <String, Object?>{
          for (final e in it.row.entries)
            if (cols.contains(e.key)) e.key: e.value is String && remap.containsKey(e.value) ? remap[e.value] : e.value
        };
        // parent checks
        String? why;
        for (final ref in _refsOf(it.table, row)) {
          if (skippedIds.contains(ref.$2)) { why = 'parent was skipped'; break; }
          if (!await exists(ref.$1, ref.$2)) { why = 'missing ${ref.$1} ${ref.$2}'; break; }
        }
        if (why != null) {
          skippedIds.add(it.id);
          res.skipped++;
          if (why != 'parent was skipped') res.errors.add('${it.table} "${it.label}": $why');
          continue;
        }
        final info = db.allTables.firstWhere((x) => x.actualTableName == it.table);
        if (it.decision == Decision.replace) {
          final before = await rowOf(entity, it.id);
          final set = [for (final k in row.keys) if (k != 'id' && k != 'created_at') k];
          await db.customUpdate(
              'UPDATE ${it.table} SET ${set.map((k) => '$k = ?').join(', ')} WHERE id = ?',
              variables: [for (final k in set) Variable<Object>(row[k]), Variable<String>(it.id)],
              updates: {info}, updateKind: UpdateKind.update);
          await logEvent(entity, it.id, 'update', before: before, after: await rowOf(entity, it.id), batch: res.batchId);
          res.replaced++;
          continue;
        }
        // add
        final u = _uniq[it.table];
        if (u != null) {
          final found = await db.customSelect(
              'SELECT id, deleted_at FROM ${it.table} WHERE ${u.map((c) => '$c = ?').join(' AND ')}',
              variables: [for (final c in u) Variable<Object>(row[c])], readsFrom: {info}).get();
          if (found.isNotEmpty) {
            if (found.first.data['deleted_at'] != null) {
              await restore(entity, found.first.read<String>('id'), batch: res.batchId);
              res.added++;
            } else {
              res.alreadyThere++;
            }
            continue;
          }
        }
        row.putIfAbsent('created_at', _now);
        row.putIfAbsent('updated_at', _now);
        final keys = row.keys.toList();
        await db.customInsert(
            'INSERT INTO ${it.table} (${keys.join(', ')}) VALUES (${keys.map((_) => '?').join(', ')})',
            variables: [for (final k in keys) Variable<Object>(row[k])], updates: {info});
        (known[it.table] ??= {}).add(it.id);
        await logEvent(entity, it.id, 'create', after: await rowOf(entity, it.id), batch: res.batchId);
        res.added++;
      }
      final bad = await db.customSelect('PRAGMA foreign_key_check').get();
      if (bad.isNotEmpty) throw StateError('integrity check failed after import; nothing was changed');
    });
    return res;
  }

  /// (table, id) pairs this row points at (FK columns + polymorphic owners/endpoints).
  List<(String, String)> _refsOf(String table, Map<String, Object?> row) {
    final out = <(String, String)>[];
    for (final e in (_fk[table] ?? const <String, String>{}).entries) {
      final v = row[e.key];
      if (v is String) out.add((e.value, v));
    }
    void poly(String typeCol, String idCol) {
      final t = row[typeCol], id = row[idCol];
      if (t is String && id is String) {
        final tbl = entityTables[t];
        if (tbl != null) out.add((tbl, id));
      }
    }
    if (table == 'notes' || table == 'attachments') poly('owner_type', 'owner_id');
    if (table == 'connections') { poly('from_type', 'from_id'); poly('to_type', 'to_id'); }
    return out;
  }
}
