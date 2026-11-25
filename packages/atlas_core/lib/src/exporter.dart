import 'dart:convert';
import 'csv.dart';
import 'repositories.dart';

/// Dependency order: parents before children (also the import order).
const backupTables = [
  'platforms', 'identities', 'emails', 'accounts', 'projects', 'resources',
  'identity_emails', 'account_emails', 'project_accounts', 'project_resources',
  'connections', 'notes', 'attachments', 'custom_field_defs', 'custom_field_values',
];
const backupFormat = 'account-atlas';
const backupVersion = 1;

extension AtlasExport on AtlasRepo {
  Future<List<Map<String, Object?>>> dumpTable(String table) async {
    if (!backupTables.contains(table)) throw ArgumentError('table $table');
    final info = db.allTables.firstWhere((x) => x.actualTableName == table);
    final r = await db.customSelect('SELECT * FROM $table ORDER BY id', readsFrom: {info}).get();
    return [for (final x in r) Map<String, Object?>.from(x.data)];
  }

  /// Full export (tombstones included so ids/relations survive a restore).
  /// Never contains secrets: integrations are not exported at all.
  Future<String> exportJson() async {
    final tables = <String, Object?>{}, counts = <String, int>{};
    for (final t in backupTables) {
      final rows = await dumpTable(t);
      tables[t] = rows;
      counts[t] = rows.length;
    }
    return const JsonEncoder.withIndent(' ').convert({
      'format': backupFormat, 'version': backupVersion,
      'schema': db.schemaVersion, 'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'counts': counts, 'tables': tables,
    });
  }

  /// Flat CSV for one entity (accounts include platform, identity and emails by name).
  Future<String> exportCsv(String entity) async {
    switch (entity) {
      case 'accounts':
        final r = await db.customSelect(
            'SELECT a.display_name, p.name AS platform, a.username, a.profile_url, a.external_id, '
            'i.name AS identity, '
            "(SELECT group_concat(e.address, ';') FROM account_emails ae JOIN emails e ON e.id = ae.email_id "
            ' WHERE ae.account_id = a.id AND ae.deleted_at IS NULL AND e.deleted_at IS NULL) AS emails '
            'FROM accounts a JOIN platforms p ON p.id = a.platform_id '
            'LEFT JOIN identities i ON i.id = a.identity_id '
            'WHERE a.deleted_at IS NULL ORDER BY p.name, a.display_name',
            readsFrom: {db.accounts, db.platforms, db.identities, db.accountEmails, db.emails}).get();
        return toCsv([
          ['platform', 'name', 'username', 'url', 'email', 'identity', 'external_id'],
          for (final x in r) [x.data['platform'], x.data['display_name'], x.data['username'],
            x.data['profile_url'], x.data['emails'], x.data['identity'], x.data['external_id']],
        ]);
      case 'platforms':
        return _simple('platforms', ['name', 'base_url', 'category'], ['name', 'url', 'category']);
      case 'emails':
        return _simple('emails', ['address', 'label'], ['address', 'label']);
      case 'projects':
        return _simple('projects', ['name', 'description', 'category', 'status'],
            ['name', 'description', 'category', 'status']);
      case 'resources':
        return _simple('resources', ['type', 'name', 'url', 'region'], ['type', 'name', 'url', 'region']);
    }
    throw ArgumentError('no CSV export for $entity');
  }

  Future<String> _simple(String table, List<String> cols, List<String> headers) async {
    final info = db.allTables.firstWhere((x) => x.actualTableName == table);
    final r = await db.customSelect(
        'SELECT ${cols.join(', ')} FROM $table WHERE deleted_at IS NULL ORDER BY ${cols.first}',
        readsFrom: {info}).get();
    return toCsv([headers, for (final x in r) [for (final c in cols) x.data[c]]]);
  }
}
