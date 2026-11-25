import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opens the encrypted database. [hexKey] = 64 hex chars (256-bit random key
/// kept in the OS secure store, never in the DB or backups).
QueryExecutor openEncrypted(File file, String hexKey) {
  assert(RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexKey), 'key must be 256-bit hex');
  return NativeDatabase(file, setup: (raw) {
    assert(_hasCipher(raw), 'SQLite3MultipleCiphers not bundled');
    raw.execute("PRAGMA key = \"x'$hexKey'\";");
  });
}

bool _hasCipher(Database db) => db.select('PRAGMA cipher;').isNotEmpty;

/// Plain in-memory DB, tests only.
QueryExecutor openInMemory() => NativeDatabase.memory();
