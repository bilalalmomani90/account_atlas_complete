import 'package:atlas_core/atlas_core.dart';
import 'package:test/test.dart';

Set<String> kinds(List<AuditIssue> l, String id) => {for (final i in l) if (i.id == id) i.kind};

void main() {
  test('audit finds gaps, ignores deleted, and clears when fixed', () async {
    final db = AtlasDatabase(openInMemory());
    final r = AtlasRepo(db);
    final p = await r.addPlatform('Empty');
    final p2 = await r.addPlatform('Used');
    final a = await r.addAccount(platformId: p2, displayName: 'acc', username: 'u');
    final e = await r.addEmail('lonely@x.io');
    final proj = await r.addProject('proj');
    final res = await r.addResource('domain', 'orphan.com');
    final iden = await r.addIdentity('Me');

    var l = await r.audit();
    expect(kinds(l, p), {'platform_empty'});
    expect(kinds(l, a), containsAll(['account_no_email', 'account_no_identity']));
    expect(kinds(l, e), {'email_unused'});
    expect(kinds(l, proj), {'project_empty'});
    expect(kinds(l, res), {'resource_orphan'});

    await r.linkAccountEmailOnce(a, e);
    await r.setAccountIdentity(a, iden);
    await r.linkProjectAccount(proj, a);
    l = await r.audit();
    expect(kinds(l, a), isEmpty);
    expect(kinds(l, e), isEmpty);
    expect(kinds(l, proj), isEmpty);

    await r.softDelete('platform', p);
    expect(kinds(await r.audit(), p), isEmpty);
  });

  test('stale accounts, markReviewed, renewal window, needs_review', () async {
    final db = AtlasDatabase(openInMemory());
    final r = AtlasRepo(db);
    final p = await r.addPlatform('S');
    final a = await r.addAccount(platformId: p, displayName: 'old', username: 'o');
    final future = DateTime.now().add(const Duration(days: 400));
    expect(kinds(await r.audit(now: future), a), contains('account_stale'));
    expect(kinds(await r.audit(), a), isNot(contains('account_stale')));

    await r.markReviewed(a);
    expect(kinds(await r.audit(now: future), a), contains('account_stale')); // 400d after review is stale again
    expect(kinds(await r.audit(now: DateTime.now().add(const Duration(days: 100))), a), isNot(contains('account_stale')));

    final res = await r.addResource('domain', 'd.com', platformId: p);
    await r.updateFields('resource', res, {'renewal_date': DateTime.now().add(const Duration(days: 10)).millisecondsSinceEpoch ~/ 1000});
    expect(kinds(await r.audit(), res), contains('renewal_soon'));
    await r.updateFields('resource', res, {'needs_review': 1, 'review_reason': 'missing_from_source'});
    final it = (await r.audit()).firstWhere((i) => i.kind == 'needs_review');
    expect(it.detail, 'missing_from_source');
  });
}
