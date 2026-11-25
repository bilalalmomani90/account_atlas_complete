import 'dart:convert';
import 'package:atlas_core/atlas_core.dart';
import 'package:test/test.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;

class FakeHttp implements Http {
  FakeHttp(this.routes);
  final Map<String, HttpResp Function(Uri, String?)> routes;
  final calls = <String>[];
  @override
  Future<HttpResp> send(String method, Uri url, {Map<String, String>? headers, String? body}) async {
    calls.add('$method ${url.path}');
    final k = '$method ${url.host}${url.path}';
    final f = routes[k];
    if (f == null) return HttpResp(404, {}, '{}');
    return f(url, body);
  }
}

HttpResp ok(Object j) => HttpResp(200, {}, jsonEncode(j));

FakeHttp githubHttp({List<Map<String, Object?>>? repos}) => FakeHttp({
      'GET api.github.com/user': (_, __) =>
          ok({'id': 42, 'login': 'Octo', 'name': 'Octo Cat', 'html_url': 'https://github.com/Octo'}),
      'GET api.github.com/user/emails': (_, __) => ok([
            {'email': 'me@x.io'},
            {'email': '1+octo@users.noreply.github.com'}
          ]),
      'GET api.github.com/user/repos': (_, __) => ok(repos ??
          [
            {'id': 1, 'full_name': 'Octo/a', 'html_url': 'https://github.com/Octo/a'},
            {'id': 2, 'full_name': 'Octo/b', 'html_url': 'https://github.com/Octo/b'},
          ]),
    });

void main() {
  test('device flow: pending -> slow_down -> token, no real waiting', () async {
    var n = 0;
    final http = FakeHttp({
      'POST github.com/login/device/code': (_, __) => ok(
          {'device_code': 'd', 'user_code': 'AB-CD', 'verification_uri': 'https://github.com/login/device', 'expires_in': 900, 'interval': 5}),
      'POST github.com/login/oauth/access_token': (_, __) {
        n++;
        if (n == 1) return ok({'error': 'authorization_pending'});
        if (n == 2) return ok({'error': 'slow_down', 'interval': 10});
        return ok({'access_token': 'tok'});
      },
    });
    final f = GithubDeviceFlow(http, 'cid');
    final c = await f.start();
    final waits = <int>[];
    final t = await f.poll(c, wait: (d) async => waits.add(d.inSeconds));
    expect(t, 'tok');
    expect(waits, [5, 5, 10]);
  });

  test('device flow: denied and expired raise auth errors', () async {
    for (final e in ['access_denied', 'expired_token']) {
      final http = FakeHttp({
        'POST github.com/login/oauth/access_token': (_, __) => ok({'error': e}),
      });
      final f = GithubDeviceFlow(http, 'cid');
      await expectLater(
          f.poll(DeviceCode('d', 'u', 'v', 900, 5), wait: (_) async {}), throwsA(isA<IntegrationException>()));
    }
  });

  test('github sync: adds, is idempotent, adopts manual account, token only in secret store', () async {
    final db = AtlasDatabase(openInMemory());
    final repo = AtlasRepo(db);
    final gh = await repo.addPlatform('GitHub', baseUrl: 'https://github.com');
    final manual = await repo.addAccount(platformId: gh, displayName: 'mine', username: 'octo');
    final secrets = MemorySecretStore();
    final svc = IntegrationService(db, secrets, {'github': GithubProvider(githubHttp())});
    final id = await svc.connect('github', 'oauth_device', 'SECRET-TOKEN', scopes: 'read:user user:email');

    final s1 = await svc.sync(id);
    expect(s1.adopted, 1); // manual account adopted, no duplicate
    expect(s1.added, 2); // two repos
    final accounts = await (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get();
    expect(accounts.length, 1);
    expect(accounts.single.id, manual);
    expect(accounts.single.externalId, '42');
    expect((await repo.accountsForEmail((await db.select(db.emails).getSingle()).id)).length, 1);
    expect((await db.select(db.emails).get()).length, 1); // noreply filtered

    final s2 = await svc.sync(id);
    expect(s2.added + s2.adopted + s2.updated, 0); // idempotent
    expect((await db.select(db.resources).get()).length, 2);

    // token never written to DB
    final dump = await db.customSelect('SELECT secret_ref FROM integrations').get();
    expect(dump.single.read<String>('secret_ref'), startsWith('integration:'));
    expect(await secrets.read('integration:$id'), 'SECRET-TOKEN');
    final hist = await db.select(db.syncHistory).get();
    expect(hist.length, 2);
    expect(hist.every((h) => h.result == 'ok'), isTrue);
    expect(jsonEncode(hist.map((h) => h.counts).toList()).contains('SECRET'), isFalse);
  });

  test('disappeared repo is flagged needs_review, never deleted; reappearing clears the flag', () async {
    final db = AtlasDatabase(openInMemory());
    final secrets = MemorySecretStore();
    var repos = <Map<String, Object?>>[
      {'id': 1, 'full_name': 'Octo/a', 'html_url': 'u1'},
      {'id': 2, 'full_name': 'Octo/b', 'html_url': 'u2'},
    ];
    final http = FakeHttp({
      ...githubHttp().routes,
      'GET api.github.com/user/repos': (_, __) => ok(repos),
    });
    final svc = IntegrationService(db, secrets, {'github': GithubProvider(http)});
    final id = await svc.connect('github', 'pat', 't');
    await svc.sync(id);
    repos = [repos.first];
    final s = await svc.sync(id);
    expect(s.flagged, 1);
    final b = await (db.select(db.resources)..where((t) => t.name.equals('Octo/b'))).getSingle();
    expect(b.needsReview, isTrue);
    expect(b.reviewReason, 'missing_from_source');
    expect(b.deletedAt, isNull);
    repos = [
      {'id': 1, 'full_name': 'Octo/a', 'html_url': 'u1'},
      {'id': 2, 'full_name': 'Octo/b', 'html_url': 'u2'},
    ];
    final s3 = await svc.sync(id);
    expect(s3.unflagged, 1);
  });

  test('user-deleted discovered item is not resurrected; manual edits survive; batch undo works', () async {
    final db = AtlasDatabase(openInMemory());
    final repo = AtlasRepo(db);
    final svc = IntegrationService(db, MemorySecretStore(), {'github': GithubProvider(githubHttp())});
    final id = await svc.connect('github', 'pat', 't');
    await svc.sync(id);
    final a = await (db.select(db.resources)..where((t) => t.name.equals('Octo/a'))).getSingle();
    await repo.softDelete('resource', a.id);
    await svc.sync(id);
    final again = await (db.select(db.resources)..where((t) => t.id.equals(a.id))).getSingle();
    expect(again.deletedAt, isNotNull);
    expect((await db.select(db.resources).get()).length, 2);

    final batches = await db.customSelect(
        "SELECT DISTINCT batch_id AS b FROM activity_log WHERE batch_id LIKE 'sync-github-%' ORDER BY rowid").get();
    expect(batches, isNotEmpty);
    final first = batches.first.read<String>('b');
    await repo.undoBatch(first);
    expect((await (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get()).length, 0);
  });

  test('errors: 401 -> auth_expired, 429 -> rate_limited with reset; messages carry no token', () async {
    for (final (code, headers, status) in [
      (401, <String, String>{}, 'auth_expired'),
      (429, {'x-ratelimit-reset': '2000000000'}, 'rate_limited'),
    ]) {
      final db = AtlasDatabase(openInMemory());
      final http = FakeHttp({'GET api.supabase.com/v1/projects': (_, __) => HttpResp(code, headers, 'LEAK-SECRET')});
      final svc = IntegrationService(db, MemorySecretStore(), {'supabase': SupabaseProvider(http)});
      final id = await svc.connect('supabase', 'pat', 'T');
      await expectLater(svc.sync(id), throwsA(isA<IntegrationException>()));
      final i = await (db.select(db.integrations)..where((t) => t.id.equals(id))).getSingle();
      expect(i.status, status);
      final h = await db.select(db.syncHistory).getSingle();
      expect(h.result, 'failed');
      expect(h.error!.contains('LEAK'), isFalse);
    }
  });

  test('supabase and firebase (paged) discovery', () async {
    final db = AtlasDatabase(openInMemory());
    final http = FakeHttp({
      'GET api.supabase.com/v1/projects': (_, __) => ok([
            {'ref': 'abcdefghijklmnopqrst', 'name': 'prod', 'region': 'eu-west-1'}
          ]),
      'GET firebase.googleapis.com/v1beta1/projects': (u, __) => u.queryParameters['pageToken'] == null
          ? ok({'results': [{'projectId': 'p1', 'displayName': 'One'}], 'nextPageToken': 'n'})
          : ok({'results': [{'projectId': 'p2'}]}),
    });
    final svc = IntegrationService(db, MemorySecretStore(),
        {'supabase': SupabaseProvider(http), 'firebase': FirebaseProvider(http)});
    final a = await svc.connect('supabase', 'pat', 't');
    final b = await svc.connect('firebase', 'oauth_token', 't');
    expect((await svc.sync(a)).added, 1);
    expect((await svc.sync(b)).added, 2);
    final names = (await db.select(db.resources).get()).map((r) => r.name).toSet();
    expect(names, {'prod', 'One', 'p2'});
    await svc.disconnect(a);
    final i = await (db.select(db.integrations)..where((t) => t.id.equals(a))).getSingle();
    expect(i.secretRef, isNull);
    expect(i.status, 'disconnected');
  });
}
