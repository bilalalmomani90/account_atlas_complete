import 'dart:io';
import 'package:atlas_core/atlas_core.dart';
import 'package:test/test.dart';

const it = 1000; // fast KDF for tests only

Future<(AtlasDatabase, AtlasRepo)> fresh() async {
  final d = AtlasDatabase(openInMemory());
  return (d, AtlasRepo(d));
}

Future<Map<String, Object?>> snap(AtlasRepo r) async => {
      for (final t in backupTables) t: (await r.dumpTable(t))
    };

void main() {
  test('encrypt/decrypt roundtrip, wrong password, tampering', () async {
    final env = await encryptText('سر {"a":1}', 'pw', iterations: it);
    expect(isEncrypted(env), isTrue);
    expect(env.contains('سر'), isFalse);
    expect(await decryptText(env, 'pw'), 'سر {"a":1}');
    await expectLater(decryptText(env, 'bad'), throwsA(isA<BadPassword>()));
    final tampered = env.replaceFirst('"iterations":1000', '"iterations":1001');
    await expectLater(decryptText(tampered, 'pw'), throwsA(anything));
    await expectLater(decryptText('{"format":"x"}', 'pw'), throwsA(isA<FormatException>()));
    await expectLater(decryptText(env.replaceFirst('"iterations":1000', '"iterations":1'), 'pw'),
        throwsA(isA<FormatException>()));
    // fresh salt/nonce each time
    expect(await encryptText('a', 'pw', iterations: it) == await encryptText('a', 'pw', iterations: it), isFalse);
  });

  test('encrypted backup: verify then restore into an empty database', () async {
    final (_, a) = await fresh();
    final p = await a.addPlatform('GitHub', baseUrl: 'https://github.com');
    final acc = await a.addAccount(platformId: p, displayName: 'me', username: 'me');
    final e = await a.addEmail('x@y.io');
    await a.linkAccountEmailOnce(acc, e);
    final env = await a.exportEncrypted('pw', iterations: it);
    expect((await a.verifyEncrypted(env, 'pw')).ok, isTrue);
    final before = {for (final x in backupTables) x: [for (final r in await a.dumpTable(x)) r['id']]};
    await a.addEmail('later@y.io'); // DB changed after the backup -> verify must notice
    expect((await a.verifyEncrypted(env, 'pw')).ok, isFalse);

    final (_, b) = await fresh();
    final plan = await b.planEncryptedRestore(env, 'pw');
    await b.applyImport(plan);
    final after = {for (final x in backupTables) x: [for (final r in await b.dumpTable(x)) r['id']]};
    expect(after, before);
  });

  test('PIN hash verify + backoff', () async {
    final h = await hashPin('1234', iterations: it);
    expect(await verifyPin('1234', h), isTrue);
    expect(await verifyPin('1235', h), isFalse);
    expect(await verifyPin('1234', 'garbage'), isFalse);
    expect(h.contains('1234'), isFalse);
    expect([0, 2, 3, 4, 10].map(pinDelaySeconds), [0, 0, 5, 10, 300]);
  });

  group('folder sync', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('atlas_sync'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<(AtlasRepo, FolderSync)> device() async {
      final (_, r) = await fresh();
      return (r, FolderSync(r, deviceId: FolderSync.newDeviceId(), iterations: it));
    }

    test('A -> B propagation, idempotent, tombstones travel, converge', () async {
      final (a, sa) = await device();
      final (b, sb) = await device();
      final p = await a.addPlatform('GitHub');
      final acc = await a.addAccount(platformId: p, displayName: 'one', username: 'u');
      await sa.run(dir, 'pw');
      final r1 = await sb.run(dir, 'pw');
      expect(r1.inserted, 2);
      await sb.run(dir, 'pw');
      expect(await snap(a), await snap(b));

      await a.softDelete('account', acc);
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      expect(await snap(a), await snap(b));
      final row = (await b.dumpTable('accounts')).single;
      expect(row['deleted_at'], isNotNull); // soft delete, row still exists
    });

    test('concurrent edits: deterministic winner, conflict logged, both devices converge', () async {
      final (a, sa) = await device();
      final (b, sb) = await device();
      final p = await a.addPlatform('Site');
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      await Future<void>.delayed(const Duration(milliseconds: 1100)); // keep edits after the last-sync second
      await a.updateFields('platform', p, {'name': 'From A'});
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await b.updateFields('platform', p, {'name': 'From B'});
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      final na = (await a.dumpTable('platforms')).single['name'];
      final nb = (await b.dumpTable('platforms')).single['name'];
      expect(na, nb);
      expect(na, 'From B'); // newer write wins
      final cs = [...await sa.conflicts(), ...await sb.conflicts()];
      expect(cs, isNotEmpty);
    });

    test('resolve conflict with the other version propagates', () async {
      final (a, sa) = await device();
      final (b, sb) = await device();
      final p = await a.addPlatform('Site');
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      await Future<void>.delayed(const Duration(milliseconds: 1100)); // keep edits after the last-sync second
      await a.updateFields('platform', p, {'name': 'From A'});
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await b.updateFields('platform', p, {'name': 'From B'});
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      final c = (await sb.conflicts()).isNotEmpty ? (await sb.conflicts()).first : (await sa.conflicts()).first;
      final owner = (await sb.conflicts()).isNotEmpty ? sb : sa;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await owner.resolveConflict(c.id, useOther: true);
      expect(await owner.conflicts(), isEmpty);
      await sa.run(dir, 'pw');
      await sb.run(dir, 'pw');
      await sa.run(dir, 'pw');
      expect((await a.dumpTable('platforms')).single['name'], (await b.dumpTable('platforms')).single['name']);
      expect((await a.dumpTable('platforms')).single['name'], 'From A');
    });

    test('wrong password and foreign file do not corrupt data', () async {
      final (a, sa) = await device();
      final (b, sb) = await device();
      await a.addPlatform('X');
      await sa.run(dir, 'pw');
      File('${dir.path}/junk$syncExt').writeAsStringSync('not json');
      final r = await sb.run(dir, 'other');
      expect(r.problems, isNotEmpty);
      expect(await b.dumpTable('platforms'), isEmpty);
      expect((await sb.lastSync()), isNull); // partial result is not a successful sync
    });
  });
}

