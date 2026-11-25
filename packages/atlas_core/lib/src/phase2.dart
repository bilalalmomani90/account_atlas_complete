import 'dart:convert';
import 'package:drift/drift.dart';
import 'database.dart';
import 'repositories.dart';

/// entity name -> SQL table (whitelist: raw SQL below only ever uses these).
const entityTables = {
  'platform': 'platforms', 'identity': 'identities', 'email': 'emails',
  'account': 'accounts', 'project': 'projects', 'resource': 'resources',
  'note': 'notes', 'identity_email': 'identity_emails',
  'account_email': 'account_emails', 'project_account': 'project_accounts',
  'project_resource': 'project_resources', 'connection': 'connections',
  'attachment': 'attachments', 'custom_field_def': 'custom_field_defs',
  'custom_field_value': 'custom_field_values',
};

final _colRe = RegExp(r'^[a-z][a-z_]*$');
int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000; // Drift default: unix seconds

/// One row of a relation list (link row id, the other side, display text).
class RelRow {
  RelRow(this.linkId, this.otherId, this.label, this.sub);
  final String linkId, otherId, label;
  final String? sub;
}

class SearchHit {
  SearchHit(this.type, this.id, this.title, [this.sub]);
  final String type, id, title;
  final String? sub;
}

/// Arabic-aware normalisation: strips tashkeel/tatweel, unifies alef, ya, ta marbuta.
String normalizeText(String s) {
  final sb = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    if ((r >= 0x064B && r <= 0x065F) || r == 0x0670 || r == 0x0640) continue;
    switch (r) {
      case 0x0623: case 0x0625: case 0x0622: sb.writeCharCode(0x0627);
      case 0x0649: sb.writeCharCode(0x064A);
      case 0x0629: sb.writeCharCode(0x0647);
      default: sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

extension AtlasPhase2 on AtlasRepo {
  String _t(String entity) =>
      entityTables[entity] ?? (throw ArgumentError('unknown entity $entity'));

  TableInfo _info(String table) => db.allTables.firstWhere((x) => x.actualTableName == table);

  Future<Map<String, Object?>?> _row(String table, String id) async {
    final r = await db.customSelect('SELECT * FROM $table WHERE id = ?',
        variables: [Variable<String>(id)], readsFrom: {_info(table)}).get();
    return r.isEmpty ? null : Map<String, Object?>.from(r.first.data);
  }

  Future<void> _log(String entity, String id, String action,
      Map<String, Object?>? before, Map<String, Object?>? after, {String? batch}) =>
      db.into(db.activityLog).insert(ActivityLogCompanion.insert(
          entityType: entity, entityId: id, action: action,
          beforeJson: Value(before == null ? null : jsonEncode(before)),
          afterJson: Value(after == null ? null : jsonEncode(after)),
          batchId: Value(batch)));

  Future<void> logCreated(String entity, String id) async =>
      _log(entity, id, 'create', null, await _row(_t(entity), id));

  Future<void> _apply(String entity, String id, Map<String, Object?> changes,
      String action, {String? batch, bool undoable = true}) async {
    final t = _t(entity);
    for (final k in changes.keys) {
      if (!_colRe.hasMatch(k)) throw ArgumentError('bad column $k');
    }
    await db.transaction(() async {
      final before = await _row(t, id);
      if (before == null) throw StateError('$entity $id not found');
      final sets = [for (final k in changes.keys) '$k = ?', 'updated_at = ?'].join(', ');
      await db.customUpdate('UPDATE $t SET $sets WHERE id = ?',
          variables: [
            for (final v in changes.values) Variable<Object>(v),
            Variable<int>(_now()), Variable<String>(id),
          ],
          updates: {_info(t)}, updateKind: UpdateKind.update);
      final after = await _row(t, id);
      await _log(entity, id, action, before, after, batch: batch);
    });
  }

  /// Edit fields by column name (snake_case). Logged, undoable.
  Future<void> updateFields(String entity, String id, Map<String, Object?> changes, {String? batch}) =>
      _apply(entity, id, changes, 'update', batch: batch);

  Future<void> softDelete(String entity, String id, {String? batch}) =>
      _apply(entity, id, {'deleted_at': _now()}, 'delete', batch: batch);

  Future<void> restore(String entity, String id, {String? batch}) =>
      _apply(entity, id, {'deleted_at': null}, 'restore', batch: batch);

  /// Public hooks for the importer (raw inserts still get logged, undoably).
  Future<Map<String, Object?>?> rowOf(String entity, String id) => _row(_t(entity), id);
  Future<void> logEvent(String entity, String id, String action,
          {Map<String, Object?>? before, Map<String, Object?>? after, String? batch}) =>
      _log(entity, id, action, before, after, batch: batch);

  /// Reverts every undoable entry of a batch (newest first). Used for imports and merges.
  Future<int> undoBatch(String batchId) async {
    final entries = await (db.select(db.activityLog)
          ..where((t) => t.batchId.equals(batchId) & t.undoable.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(CustomExpression<int>('rowid'))]))
        .get();
    var n = 0;
    await db.transaction(() async {
      for (final e in entries) {
        if (await undo(e.id)) n++;
      }
    });
    return n;
  }

  /// Reverts one activity entry. Returns false if it cannot be undone.
  Future<bool> undo(String logId) async {
    final log = await (db.select(db.activityLog)..where((t) => t.id.equals(logId))).getSingleOrNull();
    if (log == null || !log.undoable) return false;
    final e = log.entityType, id = log.entityId;
    switch (log.action) {
      case 'create': await _apply(e, id, {'deleted_at': _now()}, 'undo', undoable: false);
      case 'delete': await _apply(e, id, {'deleted_at': null}, 'undo', undoable: false);
      case 'update':
        final b = jsonDecode(log.beforeJson!) as Map<String, dynamic>;
        final a = jsonDecode(log.afterJson!) as Map<String, dynamic>;
        final ch = <String, Object?>{
          for (final k in b.keys)
            if (k != 'id' && k != 'updated_at' && k != 'created_at' && b[k] != a[k]) k: b[k]
        };
        if (ch.isNotEmpty) await _apply(e, id, ch, 'undo', undoable: false);
      default: return false;
    }
    await (db.update(db.activityLog)..where((t) => t.id.equals(logId)))
        .write(const ActivityLogCompanion(undoable: Value(false)));
    return true;
  }

  Stream<List<ActivityLogData>> watchActivity({int limit = 100}) =>
      (db.select(db.activityLog)
            ..orderBy([(t) => OrderingTerm.desc(CustomExpression<int>('rowid'))])
            ..limit(limit))
          .watch();

  // ---------- links (idempotent; re-linking restores a tombstoned link) ----------
  Future<String> _linkOnce(String entity, Map<String, String> keys,
      Future<String> Function() create) async {
    final t = _t(entity);
    for (final k in keys.keys) {
      if (!_colRe.hasMatch(k)) throw ArgumentError('bad column $k');
    }
    final where = keys.keys.map((k) => '$k = ?').join(' AND ');
    final r = await db.customSelect('SELECT id, deleted_at FROM $t WHERE $where',
        variables: [for (final v in keys.values) Variable<String>(v)],
        readsFrom: {_info(t)}).get();
    if (r.isNotEmpty) {
      final id = r.first.read<String>('id');
      if (r.first.data['deleted_at'] != null) await restore(entity, id);
      return id;
    }
    final id = await create();
    await logCreated(entity, id);
    return id;
  }

  Future<String> linkAccountEmailOnce(String accountId, String emailId, {String role = 'login'}) =>
      _linkOnce('account_email', {'account_id': accountId, 'email_id': emailId, 'role': role},
          () async => (await db.into(db.accountEmails).insertReturning(AccountEmailsCompanion.insert(
              accountId: accountId, emailId: emailId, role: Value(role)))).id);

  Future<String> linkIdentityEmail(String identityId, String emailId) =>
      _linkOnce('identity_email', {'identity_id': identityId, 'email_id': emailId},
          () async => (await db.into(db.identityEmails).insertReturning(
              IdentityEmailsCompanion.insert(identityId: identityId, emailId: emailId))).id);

  Future<String> linkProjectAccount(String projectId, String accountId, {String role = 'owner'}) =>
      _linkOnce('project_account', {'project_id': projectId, 'account_id': accountId, 'role': role},
          () async => (await db.into(db.projectAccounts).insertReturning(ProjectAccountsCompanion.insert(
              projectId: projectId, accountId: accountId, role: Value(role)))).id);

  Future<String> linkProjectResource(String projectId, String resourceId) =>
      _linkOnce('project_resource', {'project_id': projectId, 'resource_id': resourceId},
          () async => (await db.into(db.projectResources).insertReturning(
              ProjectResourcesCompanion.insert(projectId: projectId, resourceId: resourceId))).id);

  Future<String> addConnection(String fromType, String fromId, String toType, String toId,
      String kind, {String? label}) async {
    final row = await db.into(db.connections).insertReturning(ConnectionsCompanion.insert(
        fromType: fromType, fromId: fromId, toType: toType, toId: toId, kind: kind,
        label: Value(label)));
    await logCreated('connection', row.id);
    return row.id;
  }

  Future<String> addIdentity(String name, {String? notes}) async {
    final row = await db.into(db.identities)
        .insertReturning(IdentitiesCompanion.insert(name: name, notes: Value(notes)));
    await logCreated('identity', row.id);
    return row.id;
  }

  Future<void> setAccountIdentity(String accountId, String? identityId) =>
      updateFields('account', accountId, {'identity_id': identityId});

  Future<String> addNote(String ownerType, String ownerId, String body) async {
    final row = await db.into(db.notes).insertReturning(
        NotesCompanion.insert(ownerType: ownerType, ownerId: ownerId, body: body));
    await logCreated('note', row.id);
    return row.id;
  }

  Stream<List<RelRow>> watchNotes(String ownerType, String ownerId) =>
      rels('SELECT id AS link_id, id AS other_id, body AS label, NULL AS sub FROM notes '
          'WHERE owner_type = ? AND owner_id = ? AND deleted_at IS NULL ORDER BY created_at DESC',
          [ownerType, ownerId], {db.notes});

  // ---------- relation lists for detail pages ----------
  Stream<List<RelRow>> rels(String sql, List<Object?> vars, Set<ResultSetImplementation> reads) =>
      db.customSelect(sql,
          variables: [for (final v in vars) Variable<Object>(v)], readsFrom: reads)
          .watch()
          .map((rows) => [
                for (final r in rows)
                  RelRow(r.read<String>('link_id'), r.read<String>('other_id'),
                      r.read<String>('label'), r.readNullable<String>('sub'))
              ]);

  Stream<List<RelRow>> accountEmailRels(String accountId) => rels(
      'SELECT ae.id AS link_id, e.id AS other_id, e.address AS label, ae.role AS sub '
      'FROM account_emails ae JOIN emails e ON e.id = ae.email_id '
      'WHERE ae.account_id = ? AND ae.deleted_at IS NULL AND e.deleted_at IS NULL',
      [accountId], {db.accountEmails, db.emails});

  Stream<List<RelRow>> emailAccountRels(String emailId) => rels(
      'SELECT ae.id AS link_id, a.id AS other_id, a.display_name AS label, p.name AS sub '
      'FROM account_emails ae JOIN accounts a ON a.id = ae.account_id '
      'JOIN platforms p ON p.id = a.platform_id '
      'WHERE ae.email_id = ? AND ae.deleted_at IS NULL AND a.deleted_at IS NULL',
      [emailId], {db.accountEmails, db.accounts, db.platforms});

  Stream<List<RelRow>> identityEmailRels(String identityId) => rels(
      'SELECT ie.id AS link_id, e.id AS other_id, e.address AS label, NULL AS sub '
      'FROM identity_emails ie JOIN emails e ON e.id = ie.email_id '
      'WHERE ie.identity_id = ? AND ie.deleted_at IS NULL AND e.deleted_at IS NULL',
      [identityId], {db.identityEmails, db.emails});

  /// link_id = the account id itself (remove = clear its identity_id).
  Stream<List<RelRow>> identityAccountRels(String identityId) => rels(
      'SELECT a.id AS link_id, a.id AS other_id, a.display_name AS label, p.name AS sub '
      'FROM accounts a JOIN platforms p ON p.id = a.platform_id '
      'WHERE a.identity_id = ? AND a.deleted_at IS NULL',
      [identityId], {db.accounts, db.platforms});

  Stream<List<RelRow>> projectAccountRels(String projectId) => rels(
      'SELECT pa.id AS link_id, a.id AS other_id, a.display_name AS label, p.name AS sub '
      'FROM project_accounts pa JOIN accounts a ON a.id = pa.account_id '
      'JOIN platforms p ON p.id = a.platform_id '
      'WHERE pa.project_id = ? AND pa.deleted_at IS NULL AND a.deleted_at IS NULL',
      [projectId], {db.projectAccounts, db.accounts, db.platforms});

  Stream<List<RelRow>> projectResourceRels(String projectId) => rels(
      'SELECT pr.id AS link_id, r.id AS other_id, r.name AS label, r.type AS sub '
      'FROM project_resources pr JOIN resources r ON r.id = pr.resource_id '
      'WHERE pr.project_id = ? AND pr.deleted_at IS NULL AND r.deleted_at IS NULL',
      [projectId], {db.projectResources, db.resources});

  Stream<List<RelRow>> platformAccountRels(String platformId) => rels(
      'SELECT a.id AS link_id, a.id AS other_id, a.display_name AS label, a.username AS sub '
      'FROM accounts a WHERE a.platform_id = ? AND a.deleted_at IS NULL',
      [platformId], {db.accounts});

  Stream<List<RelRow>> accountProjectRels(String accountId) => rels(
      'SELECT pa.id AS link_id, p.id AS other_id, p.name AS label, pa.role AS sub '
      'FROM project_accounts pa JOIN projects p ON p.id = pa.project_id '
      'WHERE pa.account_id = ? AND pa.deleted_at IS NULL AND p.deleted_at IS NULL',
      [accountId], {db.projectAccounts, db.projects});

  Stream<List<RelRow>> resourceProjectRels(String resourceId) => rels(
      'SELECT pr.id AS link_id, p.id AS other_id, p.name AS label, NULL AS sub '
      'FROM project_resources pr JOIN projects p ON p.id = pr.project_id '
      'WHERE pr.resource_id = ? AND pr.deleted_at IS NULL AND p.deleted_at IS NULL',
      [resourceId], {db.projectResources, db.projects});

  // ---------- global search (in-memory, Arabic-normalised) ----------
  Future<List<SearchHit>> search(String query) async {
    final tokens = normalizeText(query).split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    if (tokens.isEmpty) return [];
    final hits = <SearchHit>[];
    void scan(String type, String id, String title, String? sub, List<String?> fields) {
      final hay = normalizeText(fields.whereType<String>().join(' '));
      if (tokens.every(hay.contains)) hits.add(SearchHit(type, id, title, sub));
    }
    for (final x in await (db.select(db.platforms)..where((t) => t.deletedAt.isNull())).get()) {
      scan('platform', x.id, x.name, x.baseUrl, [x.name, x.baseUrl, x.category]);
    }
    for (final x in await (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get()) {
      scan('account', x.id, x.displayName, x.username, [x.displayName, x.username, x.profileUrl]);
    }
    for (final x in await (db.select(db.emails)..where((t) => t.deletedAt.isNull())).get()) {
      scan('email', x.id, x.address, x.label, [x.address, x.label]);
    }
    for (final x in await (db.select(db.identities)..where((t) => t.deletedAt.isNull())).get()) {
      scan('identity', x.id, x.name, null, [x.name, x.notes]);
    }
    for (final x in await (db.select(db.projects)..where((t) => t.deletedAt.isNull())).get()) {
      scan('project', x.id, x.name, x.status, [x.name, x.description, x.category]);
    }
    for (final x in await (db.select(db.resources)..where((t) => t.deletedAt.isNull())).get()) {
      scan('resource', x.id, x.name, x.type, [x.name, x.type, x.url]);
    }
    for (final x in await (db.select(db.notes)..where((t) => t.deletedAt.isNull())).get()) {
      scan(x.ownerType, x.ownerId, x.body.length > 60 ? '${x.body.substring(0, 60)}…' : x.body,
          'note', [x.body]);
    }
    return hits;
  }
}
