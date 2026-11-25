import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'exporter.dart';
import 'phase2.dart';
import 'repositories.dart';
import 'secure_backup.dart';

class SyncReport {
  int inserted = 0, updated = 0, conflicts = 0, skipped = 0, filesRead = 0;
  final problems = <String>[];
  Map<String, Object?> toJson() => {
        'inserted': inserted, 'updated': updated, 'conflicts': conflicts, 'skipped': skipped, 'files': filesRead,
      };
}

const syncExt = '.atlas-sync';

/// Optional, serverless sync: every device writes only its own encrypted snapshot into a
/// shared folder (Syncthing, a cloud-drive folder, a USB stick...) and merges the others.
/// Per-row last-writer-wins with deterministic tie-breaks; losing sides of true conflicts
/// are kept in the activity log for the user to review. Nothing is ever hard-deleted
/// (tombstones travel as ordinary rows). The activity log and integrations never sync.
class FolderSync {
  FolderSync(this.repo, {required this.deviceId, this.iterations = defaultKdfIterations});
  final AtlasRepo repo;
  final String deviceId;
  final int iterations;
  AtlasDatabase get db => repo.db;

  static String newDeviceId() => const Uuid().v4();

  Future<DateTime?> lastSync() async {
    final r = await db.customSelect(
        "SELECT MAX(started_at) AS m FROM sync_history WHERE source = 'folder' AND result = 'ok'",
        readsFrom: {db.syncHistory}).getSingle();
    final m = r.readNullable<int>('m');
    return m == null ? null : DateTime.fromMillisecondsSinceEpoch(m * 1000);
  }

  Future<SyncReport> run(Directory dir, String password) async {
    final started = DateTime.now();
    final since = (await lastSync()) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final hist = await db.into(db.syncHistory)
        .insertReturning(SyncHistoryCompanion.insert(source: 'folder', startedAt: started));
    final rep = SyncReport();
    try {
      if (!dir.existsSync()) throw FileSystemException('folder missing', dir.path);
      // 1. merge what the other devices wrote
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.endsWith(syncExt) || name == '$deviceId$syncExt') continue;
        try {
          final plain = await decryptText(await f.readAsString(), password);
          await merge(plain, since, rep);
          rep.filesRead++;
        } on BadPassword {
          rep.problems.add('$name: wrong password');
        } on FormatException catch (e) {
          rep.problems.add('$name: ${e.message}');
        }
      }
      // 2. publish our own snapshot atomically (temp file then rename)
      final own = File('${dir.path}/$deviceId$syncExt');
      final tmp = File('${own.path}.tmp');
      await tmp.writeAsString(await encryptText(await _snapshot(), password, iterations: iterations), flush: true);
      await tmp.rename(own.path);
      final ok = rep.problems.isEmpty;
      await (db.update(db.syncHistory)..where((t) => t.id.equals(hist.id))).write(SyncHistoryCompanion(
          finishedAt: Value(DateTime.now()),
          result: Value(ok ? 'ok' : 'partial'),
          counts: Value(jsonEncode(rep.toJson())),
          error: Value(ok ? null : rep.problems.join('; '))));
      return rep;
    } catch (e) {
      await (db.update(db.syncHistory)..where((t) => t.id.equals(hist.id))).write(SyncHistoryCompanion(
          finishedAt: Value(DateTime.now()), result: const Value('failed'), error: Value(e.runtimeType.toString())));
      rethrow;
    }
  }

  Future<String> _snapshot() => repo.exportJson();

  static String _canon(Map<String, Object?> r) {
    final k = r.keys.toList()..sort();
    return jsonEncode([for (final x in k) [x, r[x]]]);
  }

  /// Merges a decrypted snapshot (same JSON shape as the plain backup).
  Future<void> merge(String plain, DateTime since, SyncReport rep) async {
    final m = jsonDecode(plain);
    if (m is! Map || m['format'] != backupFormat) throw const FormatException('not a snapshot');
    final schema = m['schema'];
    if (schema is! num || schema > db.schemaVersion) throw const FormatException('newer schema: update the app first');
    final tables = m['tables'];
    if (tables is! Map) throw const FormatException('no tables');
    final sinceSec = since.millisecondsSinceEpoch ~/ 1000;
    final entityOf = {for (final e in entityTables.entries) e.value: e.key};

    await db.transaction(() async {
      for (final t in backupTables) {
        final rows = tables[t];
        if (rows is! List) continue;
        final info = db.allTables.firstWhere((x) => x.actualTableName == t);
        final cols = {
          for (final c in await db.customSelect('PRAGMA table_info($t)').get()) c.read<String>('name')
        };
        for (final raw in rows) {
          if (raw is! Map) continue;
          final remote = <String, Object?>{
            for (final e in raw.entries)
              if (cols.contains(e.key)) e.key as String: e.value
          };
          final id = remote['id'];
          if (id is! String) {
            rep.skipped++;
            continue;
          }
          final localRows = await db.customSelect('SELECT * FROM $t WHERE id = ?',
              variables: [Variable<String>(id)], readsFrom: {info}).get();
          if (localRows.isEmpty) {
            if (await _insert(t, remote)) {
              rep.inserted++;
            } else {
              rep.skipped++;
            }
            continue;
          }
          final local = Map<String, Object?>.from(localRows.first.data);
          if (_canon(local) == _canon({for (final k in local.keys) k: remote[k] ?? local[k]})) continue;
          final lu = (local['updated_at'] as int?) ?? 0, ru = (remote['updated_at'] as num?)?.toInt() ?? 0;
          final remoteWins = ru != lu ? ru > lu : _canon(remote).compareTo(_canon(local)) > 0;
          final both = lu > sinceSec && ru > sinceSec;
          if (both) {
            rep.conflicts++;
            await _logConflict(entityOf[t] ?? t, id, loser: remoteWins ? local : remote, winner: remoteWins ? remote : local);
          }
          if (remoteWins) {
            await _update(t, id, remote);
            rep.updated++;
          }
        }
      }
      final bad = await db.customSelect('PRAGMA foreign_key_check').get();
      if (bad.isNotEmpty) throw StateError('sync would break relations; rolled back');
    });
  }

  Future<bool> _insert(String t, Map<String, Object?> row) async {
    final ks = row.keys.toList();
    try {
      await db.customStatement(
          'INSERT INTO $t (${ks.join(', ')}) VALUES (${List.filled(ks.length, '?').join(', ')})',
          [for (final k in ks) row[k]]);
      return true;
    } catch (_) {
      return false; // unique collision or missing parent: left for the next round / user review
    }
  }

  Future<void> _update(String t, String id, Map<String, Object?> row) async {
    final ks = row.keys.where((k) => k != 'id').toList();
    await db.customStatement(
        'UPDATE $t SET ${[for (final k in ks) '$k = ?'].join(', ')} WHERE id = ?', [for (final k in ks) row[k], id]);
  }

  Future<void> _logConflict(String entity, String id,
      {required Map<String, Object?> loser, required Map<String, Object?> winner}) =>
      db.into(db.activityLog).insert(ActivityLogCompanion.insert(
          entityType: entity, entityId: id, action: 'conflict',
          beforeJson: Value(jsonEncode(loser)), afterJson: Value(jsonEncode(winner)),
          undoable: const Value(false)));

  /// Unresolved conflicts, newest first.
  Future<List<ActivityLogData>> conflicts() => (db.select(db.activityLog)
        ..where((t) => t.action.equals('conflict'))
        ..orderBy([(t) => OrderingTerm.desc(CustomExpression<int>('rowid'))]))
      .get();

  /// [useOther] = replace the current (winning) version with the stored losing one.
  Future<void> resolveConflict(String logId, {required bool useOther}) async {
    final e = await (db.select(db.activityLog)..where((t) => t.id.equals(logId))).getSingle();
    if (e.action != 'conflict') return;
    await db.transaction(() async {
      if (useOther) {
        final t = entityTables[e.entityType] ?? e.entityType;
        if (!backupTables.contains(t)) throw ArgumentError('table');
        final row = Map<String, Object?>.from(jsonDecode(e.beforeJson!) as Map);
        row['updated_at'] = DateTime.now().millisecondsSinceEpoch ~/ 1000; // becomes the newest, propagates
        await _update(t, e.entityId, row);
      }
      await (db.update(db.activityLog)..where((t) => t.id.equals(logId)))
          .write(const ActivityLogCompanion(action: Value('conflict_resolved')));
    });
  }
}
