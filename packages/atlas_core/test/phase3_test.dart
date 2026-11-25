import 'dart:convert';
import 'package:atlas_core/atlas_core.dart';
import 'package:test/test.dart';

Future<(AtlasDatabase, AtlasRepo)> fresh() async {
  final d = AtlasDatabase(openInMemory());
  return (d, AtlasRepo(d));
}

Future<void> seed(AtlasRepo r) async {
  final gh = await r.addPlatform('GitHub', baseUrl: 'https://github.com');
  final a1 = await r.addAccount(platformId: gh, displayName: 'one', username: 'user1');
  final a2 = await r.addAccount(platformId: gh, displayName: 'two', username: 'user2');
  final e = await r.addEmail('me@x.io');
  await r.linkAccountEmailOnce(a1, e);
  await r.linkAccountEmailOnce(a2, e);
  final i = await r.addIdentity('Me');
  await r.setAccountIdentity(a1, i);
  final p = await r.addProject('proj');
  await r.linkProjectAccount(p, a1);
  await r.addNote('account', a1, 'hello');
}

void main() {
  test('csv: quotes, newlines, BOM, semicolons', () {
    final t = parseCsv('﻿a;b\r\n"x;1";"he said ""hi""\nline2"\r\n');
    expect(t.length, 2);
    expect(t[0], ['a', 'b']);
    expect(t[1], ['x;1', 'he said "hi"\nline2']);
    expect(parseCsv(toCsv([['a', 'b,c'], ['1', '"q"']])), [['a', 'b,c'], ['1', '"q"']]);
  });

  test('backup roundtrip keeps ids and relations; re-import is a no-op', () async {
    final (d1, r1) = await fresh();
    await seed(r1);
    final json = await r1.exportJson();
    final (d2, r2) = await fresh();
    final plan = await r2.planBackup(json);
    expect(plan.count(ImportStatus.add), plan.items.length);
    final res = await r2.applyImport(plan);
    expect(res.errors, isEmpty);
    final g1 = await r1.buildGraph(), g2 = await r2.buildGraph();
    expect(g2.nodes.keys.toSet(), g1.nodes.keys.toSet());
    expect(g2.edges.length, g1.edges.length);
    expect((await r2.search('hello')).length, 1);
    final again = await r2.planBackup(json);
    expect(again.count(ImportStatus.same), again.items.length);
    expect((await r2.applyImport(again)).added, 0);
    await d1.close();
    await d2.close();
  });

  test('changed rows keep mine by default; replace is undoable as a batch', () async {
    final (d1, r1) = await fresh();
    await seed(r1);
    final json = await r1.exportJson();
    final (d2, r2) = await fresh();
    await r2.applyImport(await r2.planBackup(json));
    final acc = (await r2.watchAccounts().first).firstWhere((a) => a.displayName == 'one');
    await r1.updateFields('account', acc.id, {'display_name': 'renamed'});
    final plan = await r2.planBackup(await r1.exportJson());
    final ch = plan.items.where((i) => i.status == ImportStatus.changed).toList();
    expect(ch.length, 1);
    expect(ch.single.decision, Decision.skip);
    await r2.applyImport(plan);
    expect((await r2.watchAccounts().first).any((a) => a.displayName == 'one'), isTrue);
    ch.single.decision = Decision.replace;
    final res = await r2.applyImport(plan);
    expect(res.replaced, 1);
    expect((await r2.watchAccounts().first).any((a) => a.displayName == 'renamed'), isTrue);
    await r2.undoBatch(res.batchId);
    expect((await r2.watchAccounts().first).any((a) => a.displayName == 'one'), isTrue);
    await d1.close();
    await d2.close();
  });

  test('tampered backups are rejected or reported, never half-applied silently', () async {
    final (d1, r1) = await fresh();
    await seed(r1);
    final m = jsonDecode(await r1.exportJson()) as Map<String, dynamic>;
    (m['counts'] as Map)['emails'] = 99;
    final (d2, r2) = await fresh();
    expect(() => r2.planBackup(jsonEncode(m)), throwsA(isA<FormatException>()));
    expect(() => r2.planBackup('{"nope":1}'), throwsA(isA<FormatException>()));
    // dangling relation
    final m2 = jsonDecode(await r1.exportJson()) as Map<String, dynamic>;
    final ae = (m2['tables']['account_emails'] as List).first as Map;
    ae['email_id'] = 'does-not-exist';
    final res = await r2.applyImport(await r2.planBackup(jsonEncode(m2)));
    expect(res.errors.length, 1);
    expect((await r2.watchAccounts().first).length, 2); // the rest was imported
    await d1.close();
    await d2.close();
  });

  test('csv accounts: reuse platform/email, flag duplicates, shared email != duplicate', () async {
    final (d, r) = await fresh();
    await seed(r);
    final csv = 'Site,Account,User,Email\n'
        'github ,three,user3,me@x.io;new@x.io\n'
        'GitHub,dup of one,USER1,other@x.io\n'
        'Gitlab,four,u4,\n'
        ',nosite,,\n';
    final t = parseCsv(csv);
    final map = guessMapping('accounts', t.first);
    expect(map.keys.toSet(), {'platform', 'name', 'username', 'email'});
    final plan = await r.planCsv('accounts', t, map, source: 't.csv');
    expect(plan.count(ImportStatus.duplicate), 1);
    expect(plan.count(ImportStatus.problem), 1);
    expect(plan.items.where((i) => i.table == 'platforms').length, 1); // only Gitlab is new
    expect(plan.items.where((i) => i.table == 'emails').length, 1); // only new@x.io is new
    final res = await r.applyImport(plan);
    expect(res.errors, isEmpty);
    final accs = await r.watchAccounts().first;
    expect(accs.length, 4); // one, two, three, four
    expect(accs.firstWhere((a) => a.displayName == 'three').origin, 'imported');
    expect((await r.accountsForEmail('me@x.io')).length, 3); // shared, not merged
    await r.undoBatch(res.batchId);
    expect((await r.watchAccounts().first).length, 2);
    await d.close();
  });

  test('duplicate emails: merge re-points links, undo restores', () async {
    final (d, r) = await fresh();
    final p = await r.addPlatform('P');
    final a = await r.addAccount(platformId: p, displayName: 'a');
    final b = await r.addAccount(platformId: p, displayName: 'b');
    final e1 = await r.addEmail('Dup@x.io');
    final e2 = await r.addEmail('dup@X.io');
    await r.linkAccountEmailOnce(a, e1);
    await r.linkAccountEmailOnce(b, e2);
    await r.linkAccountEmailOnce(a, e2); // would collide with a-e1 after the merge
    final groups = await r.findDuplicates();
    expect(groups.where((g) => g.entity == 'email').length, 1);
    expect(groups.where((g) => g.entity == 'account'), isEmpty);
    final batch = await r.mergeEntities('email', e1, e2);
    expect((await r.watchEmails().first).length, 1);
    expect((await r.emailAccountRels(e1).first).map((x) => x.otherId).toSet(), {a, b});
    await r.undoBatch(batch);
    expect((await r.watchEmails().first).length, 2);
    expect((await r.emailAccountRels(e2).first).map((x) => x.otherId).toSet(), {a, b});
    await d.close();
  });
}
