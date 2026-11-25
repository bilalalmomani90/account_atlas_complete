import 'dart:io';
import 'package:drift/native.dart';
import 'package:atlas_core/atlas_core.dart';
import 'package:drift/drift.dart';
import 'package:test/test.dart';

void main() {
  late AtlasDatabase db;
  late AtlasRepo repo;
  setUp(() {
    db = AtlasDatabase(openInMemory());
    repo = AtlasRepo(db);
  });
  tearDown(() => db.close());
  persistenceTests();
  phase2Tests();

  test('two accounts, same platform and same email stay separate', () async {
    final gh = await repo.addPlatform('GitHub');
    final a1 = await repo.addAccount(platformId: gh, displayName: 'one');
    final a2 = await repo.addAccount(platformId: gh, displayName: 'two');
    final e = await repo.addEmail('Me@Example.com');
    await repo.linkAccountEmail(a1, e);
    await repo.linkAccountEmail(a2, e);
    final found = await repo.accountsForEmail('me@example.COM');
    expect(found.map((a) => a.id).toSet(), {a1, a2}); // not merged
    expect((await repo.accountsOfPlatform(gh)).length, 2);
  });

  test('foreign keys are enforced', () async {
    expect(() => repo.addAccount(platformId: 'missing', displayName: 'x'),
        throwsA(anything));
  });

  test('soft delete keeps row and relations', () async {
    final p = await repo.addPlatform('Supabase');
    final a = await repo.addAccount(platformId: p, displayName: 'a');
    final e = await repo.addEmail('x@y.z');
    await repo.linkAccountEmail(a, e);
    await repo.softDeleteAccount(a);
    expect(await repo.accountsOfPlatform(p), isEmpty);
    final raw = await db.select(db.accounts).get();
    expect(raw.single.deletedAt, isNotNull);
    expect((await db.select(db.accountEmails).get()).length, 1);
  });

  test('defaults: origin manual, needsReview false, UUID ids', () async {
    final p = await repo.addPlatform('X');
    final row = await (db.select(db.platforms)..where((t) => t.id.equals(p))).getSingle();
    expect(row.origin, 'manual');
    expect(row.needsReview, isFalse);
    expect(p.length, 36);
  });
}

// ---- persistence + schema version (added for phase 1 acceptance) ----

void persistenceTests() {
  test('data survives closing and reopening the file', () async {
    final dir = Directory.systemTemp.createTempSync('atlas_t');
    final f = File('${dir.path}/t.db');
    var d = AtlasDatabase(NativeDatabase(f));
    final id = await AtlasRepo(d).addPlatform('Persist');
    await d.close();
    d = AtlasDatabase(NativeDatabase(f));
    final rows = await d.select(d.platforms).get();
    expect(rows.single.id, id);
    final v = await d.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, d.schemaVersion);
    await d.close();
    dir.deleteSync(recursive: true);
  });

  test('accounts without email are reported as incomplete', () async {
    final d = AtlasDatabase(openInMemory());
    final r = AtlasRepo(d);
    final p = await r.addPlatform('GitHub');
    final a = await r.addAccount(platformId: p, displayName: 'lonely');
    expect((await r.watchAccountsMissingEmail().first).map((x) => x.id), [a]);
    await r.linkAccountEmail(a, await r.addEmail('a@b.c'));
    expect(await r.watchAccountsMissingEmail().first, isEmpty);
    await d.close();
  });
}

void phase2Tests() {
  test('identity layer: accounts stay separate, link/unlink is idempotent', () async {
    final d = AtlasDatabase(openInMemory());
    final r = AtlasRepo(d);
    final gh = await r.addPlatform('GitHub');
    final a1 = await r.addAccount(platformId: gh, displayName: 'one');
    final a2 = await r.addAccount(platformId: gh, displayName: 'two');
    final e = await r.addEmail('m@x.io');
    final i1 = await r.addIdentity('Me');
    await r.linkIdentityEmail(i1, e);
    final l1 = await r.linkAccountEmailOnce(a1, e);
    expect(await r.linkAccountEmailOnce(a1, e), l1); // idempotent
    await r.linkAccountEmailOnce(a2, e);
    await r.setAccountIdentity(a1, i1);
    expect((await r.identityAccountRels(i1).first).map((x) => x.otherId), [a1]);
    expect((await r.emailAccountRels(e).first).length, 2); // email shared, not merged
    await r.softDelete('account_email', l1);
    expect((await r.emailAccountRels(e).first).length, 1);
    expect(await r.linkAccountEmailOnce(a1, e), l1); // restored, same id
    expect((await r.emailAccountRels(e).first).length, 2);
    await d.close();
  });

  test('undo: delete, update and create are reversible', () async {
    final d = AtlasDatabase(openInMemory());
    final r = AtlasRepo(d);
    final p = await r.addPlatform('P');
    final a = await r.addAccount(platformId: p, displayName: 'old');
    await r.updateFields('account', a, {'display_name': 'new'});
    await r.softDelete('account', a);
    var log = await r.watchActivity().first; // newest first
    expect(log.first.action, 'delete');
    expect(await r.undo(log.first.id), isTrue);
    expect((await r.accountsOfPlatform(p)).single.displayName, 'new');
    log = await r.watchActivity().first;
    final upd = log.firstWhere((l) => l.action == 'update');
    expect(await r.undo(upd.id), isTrue);
    expect((await r.accountsOfPlatform(p)).single.displayName, 'old');
    expect(await r.undo(upd.id), isFalse); // cannot undo twice
    await d.close();
  });

  test('search ignores Arabic diacritics and alef variants', () async {
    final d = AtlasDatabase(openInMemory());
    final r = AtlasRepo(d);
    await r.addProject('مَشروع أحمد');
    expect((await r.search('احمد')).length, 1);
    expect((await r.search('مشروع')).length, 1);
    expect(await r.search('zzz'), isEmpty);
    await d.close();
  });

  test('graph + layout: edges exist, positions finite', () async {
    final d = AtlasDatabase(openInMemory());
    final r = AtlasRepo(d);
    final p = await r.addPlatform('GitHub');
    final a = await r.addAccount(platformId: p, displayName: 'a');
    final e = await r.addEmail('q@w.e');
    await r.linkAccountEmailOnce(a, e);
    final pr = await r.addProject('proj');
    await r.linkProjectAccount(pr, a);
    final g = await r.buildGraph();
    expect(g.nodes.length, 4);
    expect(g.edges.length, 3); // account-platform, email-account, account-project
    final pos = forceLayout(g);
    expect(pos.values.every((q) => q.x.isFinite && q.y.isFinite), isTrue);
    expect(g.neighborhood('project:$pr', 1).nodes.length, 2);
    await d.close();
  });
}
