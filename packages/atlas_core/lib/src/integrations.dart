import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import 'database.dart';
import 'phase2.dart';
import 'repositories.dart';

// ───────────────────────── transport (injectable for tests) ─────────────────────────

class HttpResp {
  HttpResp(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers; // lower-case keys
  final String body;
  dynamic get json => jsonDecode(body);
}

abstract class Http {
  Future<HttpResp> send(String method, Uri url, {Map<String, String>? headers, String? body});
}

/// Default transport: dart:io only, no extra package.
class IoHttp implements Http {
  IoHttp({this.timeout = const Duration(seconds: 30)});
  final Duration timeout;

  @override
  Future<HttpResp> send(String method, Uri url, {Map<String, String>? headers, String? body}) async {
    final c = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await c.openUrl(method, url).timeout(timeout);
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        req.write(body);
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final h = <String, String>{};
      res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(','));
      return HttpResp(res.statusCode, h, text);
    } finally {
      c.close(force: true);
    }
  }
}

/// Where secrets live. The Flutter app implements this with the OS secure store.
abstract class SecretStore {
  Future<String?> read(String ref);
  Future<void> write(String ref, String value);
  Future<void> delete(String ref);
}

class MemorySecretStore implements SecretStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String ref) async => _m[ref];
  @override
  Future<void> write(String ref, String value) async => _m[ref] = value;
  @override
  Future<void> delete(String ref) async => _m.remove(ref);
}

/// Never carries a token or response body, only a status and a short reason.
class IntegrationException implements Exception {
  IntegrationException(this.kind, this.message, {this.status, this.retryAt});

  /// auth | rate_limited | network | api
  final String kind;
  final String message;
  final int? status;
  final DateTime? retryAt;
  @override
  String toString() => '$kind${status == null ? '' : ' ($status)'}: $message';
}

// ───────────────────────── discovery model ─────────────────────────

class DiscoveredAccount {
  DiscoveredAccount({required this.externalId, required this.displayName, this.username, this.profileUrl, this.emails = const []});
  final String externalId;
  final String displayName;
  final String? username;
  final String? profileUrl;
  final List<String> emails;
}

class DiscoveredResource {
  DiscoveredResource({required this.externalId, required this.type, required this.name, this.url, this.region});
  final String externalId;
  final String type;
  final String name;
  final String? url;
  final String? region;
}

class DiscoveryResult {
  DiscoveryResult({required this.platformName, required this.platformUrl, this.account, this.resources = const [], this.notes = const []});
  final String platformName;
  final String platformUrl;
  final DiscoveredAccount? account;
  final List<DiscoveredResource> resources;

  /// Non-fatal remarks (e.g. email scope missing). Shown to the user.
  final List<String> notes;
}

abstract class DiscoveryProvider {
  String get kind;
  Future<DiscoveryResult> discover(String token);
}

IntegrationException _fail(HttpResp r) {
  final reset = int.tryParse(r.headers['x-ratelimit-reset'] ?? '');
  final retryAfter = int.tryParse(r.headers['retry-after'] ?? '');
  if (r.status == 401) return IntegrationException('auth', 'token rejected or expired', status: 401);
  if (r.status == 429 || (r.status == 403 && r.headers['x-ratelimit-remaining'] == '0')) {
    final at = reset != null
        ? DateTime.fromMillisecondsSinceEpoch(reset * 1000)
        : retryAfter != null
            ? DateTime.now().add(Duration(seconds: retryAfter))
            : null;
    return IntegrationException('rate_limited', 'rate limit reached', status: r.status, retryAt: at);
  }
  if (r.status == 403) return IntegrationException('auth', 'permission missing for this token', status: 403);
  return IntegrationException('api', 'unexpected response', status: r.status);
}

Future<HttpResp> _get(Http http, Uri u, Map<String, String> h) async {
  try {
    return await http.send('GET', u, headers: h);
  } on SocketException {
    throw IntegrationException('network', 'cannot reach server');
  } on TimeoutException {
    throw IntegrationException('network', 'timeout');
  } on HttpException {
    throw IntegrationException('network', 'http error');
  }
}

// ───────────────────────── GitHub ─────────────────────────

class DeviceCode {
  DeviceCode(this.deviceCode, this.userCode, this.verificationUri, this.expiresIn, this.interval);
  final String deviceCode, userCode, verificationUri;
  final int expiresIn, interval;
}

/// GitHub OAuth Device Flow (no client_secret). The user must have enabled
/// "Device Flow" on their OAuth/GitHub App (documented requirement).
class GithubDeviceFlow {
  GithubDeviceFlow(this.http, this.clientId);
  final Http http;
  final String clientId;
  static const _json = {'Accept': 'application/json'};

  Future<DeviceCode> start({String scope = 'read:user user:email'}) async {
    final r = await http.send('POST', Uri.parse('https://github.com/login/device/code'),
        headers: _json, body: 'client_id=${Uri.encodeQueryComponent(clientId)}&scope=${Uri.encodeQueryComponent(scope)}');
    if (r.status != 200) throw IntegrationException('api', 'device flow start failed', status: r.status);
    final j = r.json as Map<String, dynamic>;
    if (j['error'] != null) throw IntegrationException('auth', '${j['error']}');
    return DeviceCode(j['device_code'] as String, j['user_code'] as String, j['verification_uri'] as String,
        (j['expires_in'] as num).toInt(), (j['interval'] as num).toInt());
  }

  /// Polls until authorised. [wait] is injectable so tests do not sleep.
  Future<String> poll(DeviceCode c, {Future<void> Function(Duration)? wait, bool Function()? cancelled}) async {
    wait ??= (d) => Future<void>.delayed(d);
    var interval = c.interval;
    final deadline = DateTime.now().add(Duration(seconds: c.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      if (cancelled?.call() ?? false) throw IntegrationException('auth', 'cancelled');
      await wait(Duration(seconds: interval));
      final r = await http.send('POST', Uri.parse('https://github.com/login/oauth/access_token'),
          headers: _json,
          body: 'client_id=${Uri.encodeQueryComponent(clientId)}&device_code=${Uri.encodeQueryComponent(c.deviceCode)}'
              '&grant_type=${Uri.encodeQueryComponent('urn:ietf:params:oauth:grant-type:device_code')}');
      final j = r.json as Map<String, dynamic>;
      final token = j['access_token'];
      if (token is String) return token;
      switch (j['error']) {
        case 'authorization_pending':
          break;
        case 'slow_down':
          interval = (j['interval'] as num?)?.toInt() ?? interval + 5;
        case 'expired_token':
          throw IntegrationException('auth', 'code expired');
        case 'access_denied':
          throw IntegrationException('auth', 'denied by user');
        default:
          throw IntegrationException('auth', '${j['error']}');
      }
    }
    throw IntegrationException('auth', 'code expired');
  }
}

class GithubProvider implements DiscoveryProvider {
  GithubProvider(this.http);
  final Http http;
  @override
  String get kind => 'github';

  Map<String, String> _h(String t) => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $t',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  @override
  Future<DiscoveryResult> discover(String token) async {
    final u = await _get(http, Uri.parse('https://api.github.com/user'), _h(token));
    if (u.status != 200) throw _fail(u);
    final uj = u.json as Map<String, dynamic>;
    final login = uj['login'] as String;

    final notes = <String>[];
    final emails = <String>[];
    final e = await _get(http, Uri.parse('https://api.github.com/user/emails'), _h(token));
    if (e.status == 200) {
      for (final m in e.json as List) {
        final a = (m as Map)['email'];
        if (a is String && !a.endsWith('@users.noreply.github.com')) emails.add(a);
      }
    } else if (e.status == 403 || e.status == 404) {
      notes.add('emails_scope_missing');
    } else {
      throw _fail(e);
    }

    final repos = <DiscoveredResource>[];
    for (var page = 1; page <= 50; page++) {
      final r = await _get(http,
          Uri.parse('https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner&sort=full_name'), _h(token));
      if (r.status != 200) throw _fail(r);
      final list = r.json as List;
      for (final m in list) {
        final repo = m as Map<String, dynamic>;
        repos.add(DiscoveredResource(
            externalId: '${repo['id']}', type: 'repository', name: repo['full_name'] as String, url: repo['html_url'] as String?));
      }
      if (list.length < 100) break;
    }
    return DiscoveryResult(
      platformName: 'GitHub',
      platformUrl: 'https://github.com',
      account: DiscoveredAccount(
          externalId: '${uj['id']}',
          username: login,
          displayName: (uj['name'] as String?)?.trim().isNotEmpty == true ? uj['name'] as String : login,
          profileUrl: uj['html_url'] as String?,
          emails: emails),
      resources: repos,
      notes: notes,
    );
  }
}

// ───────────────────────── Supabase ─────────────────────────

class SupabaseProvider implements DiscoveryProvider {
  SupabaseProvider(this.http);
  final Http http;
  @override
  String get kind => 'supabase';

  @override
  Future<DiscoveryResult> discover(String token) async {
    final r = await _get(http, Uri.parse('https://api.supabase.com/v1/projects'),
        {'Accept': 'application/json', 'Authorization': 'Bearer $token'});
    if (r.status != 200) throw _fail(r);
    final res = <DiscoveredResource>[];
    for (final m in r.json as List) {
      final p = m as Map<String, dynamic>;
      final ref = (p['ref'] ?? p['id']) as String;
      res.add(DiscoveredResource(
          externalId: ref,
          type: 'database',
          name: p['name'] as String,
          region: p['region'] as String?,
          url: 'https://supabase.com/dashboard/project/$ref'));
    }
    return DiscoveryResult(platformName: 'Supabase', platformUrl: 'https://supabase.com', resources: res);
  }
}

// ───────────────────────── Firebase ─────────────────────────

class FirebaseProvider implements DiscoveryProvider {
  FirebaseProvider(this.http);
  final Http http;
  @override
  String get kind => 'firebase';

  @override
  Future<DiscoveryResult> discover(String token) async {
    final res = <DiscoveredResource>[];
    String? next;
    for (var i = 0; i < 50; i++) {
      final q = {'pageSize': '100', if (next != null) 'pageToken': next};
      final r = await _get(http, Uri.https('firebase.googleapis.com', '/v1beta1/projects', q),
          {'Accept': 'application/json', 'Authorization': 'Bearer $token'});
      if (r.status != 200) throw _fail(r);
      final j = r.json as Map<String, dynamic>;
      for (final m in (j['results'] as List? ?? const [])) {
        final p = m as Map<String, dynamic>;
        final id = p['projectId'] as String;
        res.add(DiscoveredResource(
            externalId: id,
            type: 'database',
            name: (p['displayName'] as String?) ?? id,
            url: 'https://console.firebase.google.com/project/$id'));
      }
      next = j['nextPageToken'] as String?;
      if (next == null || next.isEmpty) break;
    }
    return DiscoveryResult(
        platformName: 'Firebase',
        platformUrl: 'https://firebase.google.com',
        resources: res,
        notes: const ['firebase_active_only']);
  }
}

// ───────────────────────── applying discovery to the database ─────────────────────────

class SyncSummary {
  SyncSummary({this.added = 0, this.updated = 0, this.adopted = 0, this.flagged = 0, this.unflagged = 0, this.notes = const []});
  int added, updated, adopted, flagged, unflagged;
  List<String> notes;
  Map<String, Object?> toJson() =>
      {'added': added, 'updated': updated, 'adopted': adopted, 'flagged': flagged, 'unflagged': unflagged};
}

class IntegrationService {
  IntegrationService(this.db, this.secrets, this.providers);
  final AtlasDatabase db;
  final SecretStore secrets;
  final Map<String, DiscoveryProvider> providers;

  late final AtlasRepo _repo = AtlasRepo(db);

  /// Creates the integration row and stores the token in the secure store.
  /// The database only keeps the pointer (secret_ref).
  Future<String> connect(String kind, String authType, String token, {String? scopes}) async {
    if (!providers.containsKey(kind)) throw ArgumentError('unknown integration $kind');
    final row = await db.into(db.integrations).insertReturning(
        IntegrationsCompanion.insert(kind: kind, authType: authType, scopes: Value(scopes)));
    final ref = 'integration:${row.id}';
    await secrets.write(ref, token);
    await (db.update(db.integrations)..where((t) => t.id.equals(row.id)))
        .write(IntegrationsCompanion(secretRef: Value(ref), status: const Value('connected')));
    return row.id;
  }

  /// Removes the token and marks disconnected. Discovered data is kept.
  Future<void> disconnect(String integrationId) async {
    final i = await (db.select(db.integrations)..where((t) => t.id.equals(integrationId))).getSingleOrNull();
    if (i == null) return;
    if (i.secretRef != null) await secrets.delete(i.secretRef!);
    await (db.update(db.integrations)..where((t) => t.id.equals(integrationId)))
        .write(const IntegrationsCompanion(secretRef: Value(null), status: Value('disconnected')));
  }

  Stream<List<Integration>> watchIntegrations() =>
      (db.select(db.integrations)..where((t) => t.deletedAt.isNull())).watch();

  /// Read-only discovery + apply. Never deletes; never overwrites manual data.
  Future<SyncSummary> sync(String integrationId) async {
    final i = await (db.select(db.integrations)..where((t) => t.id.equals(integrationId))).getSingle();
    final provider = providers[i.kind]!;
    final started = DateTime.now();
    final hist = await db.into(db.syncHistory).insertReturning(
        SyncHistoryCompanion.insert(source: 'integration:${i.kind}', startedAt: started));
    Future<void> finish(String result, {SyncSummary? s, String? error, String? status}) async {
      await (db.update(db.syncHistory)..where((t) => t.id.equals(hist.id))).write(SyncHistoryCompanion(
          finishedAt: Value(DateTime.now()),
          result: Value(result),
          counts: Value(s == null ? null : jsonEncode(s.toJson())),
          error: Value(error)));
      await (db.update(db.integrations)..where((t) => t.id.equals(integrationId))).write(IntegrationsCompanion(
          status: Value(status ?? (result == 'ok' ? 'connected' : 'error')),
          lastSyncAt: result == 'ok' ? Value(DateTime.now()) : const Value.absent()));
    }

    try {
      final token = i.secretRef == null ? null : await secrets.read(i.secretRef!);
      if (token == null) throw IntegrationException('auth', 'no token stored');
      final result = await provider.discover(token);
      final s = await _apply(i.kind, integrationId, result);
      await finish('ok', s: s);
      return s;
    } on IntegrationException catch (e) {
      await finish('failed',
          error: e.toString(), status: e.kind == 'auth' ? 'auth_expired' : e.kind == 'rate_limited' ? 'rate_limited' : 'error');
      rethrow;
    }
  }

  Future<SyncSummary> _apply(String kind, String integrationId, DiscoveryResult r) async {
    final s = SyncSummary(notes: r.notes);
    final batch = 'sync-$kind-${DateTime.now().microsecondsSinceEpoch}';
    await db.transaction(() async {
      final platformId = await _platform(r.platformName, r.platformUrl, batch);
      String? accountId;
      final seenAccounts = <String>{}, seenResources = <String>{};

      final a = r.account;
      if (a != null) {
        accountId = await _account(kind, integrationId, platformId, a, batch, s);
        if (accountId != null) {
          seenAccounts.add(accountId);
          for (final addr in a.emails) {
            final emailId = await _email(addr, kind, batch);
            if (emailId != null) await _repo.linkAccountEmailOnce(accountId, emailId);
          }
        }
      }
      for (final res in r.resources) {
        final id = await _resource(kind, platformId, accountId, res, batch, s);
        if (id != null) seenResources.add(id);
      }
      await _flagMissing('account', db.accounts.actualTableName, kind, seenAccounts, batch, s);
      await _flagMissing('resource', db.resources.actualTableName, kind, seenResources, batch, s);
    });
    return s;
  }

  Future<String> _platform(String name, String url, String batch) async {
    final rows = await (db.select(db.platforms)..where((t) => t.deletedAt.isNull())).get();
    final host = Uri.parse(url).host.toLowerCase();
    for (final p in rows) {
      final h = p.baseUrl == null ? '' : (Uri.tryParse(p.baseUrl!)?.host.toLowerCase() ?? '');
      if (p.name.toLowerCase() == name.toLowerCase() || (h.isNotEmpty && h == host)) return p.id;
    }
    final row = await db.into(db.platforms).insertReturning(PlatformsCompanion.insert(
        name: name, baseUrl: Value(url), origin: const Value('discovered'), apiCapability: const Value('read')));
    await _repo.logEvent('platform', row.id, 'create', after: await _repo.rowOf('platform', row.id), batch: batch);
    return row.id;
  }

  Future<String?> _email(String address, String kind, String batch) async {
    final n = normalizeEmail(address);
    final ex = await (db.select(db.emails)..where((t) => t.addressNormalized.equals(n) & t.deletedAt.isNull())).getSingleOrNull();
    if (ex != null) return ex.id;
    final row = await db.into(db.emails).insertReturning(EmailsCompanion.insert(
        address: address.trim(), addressNormalized: n, origin: const Value('discovered'), originRef: Value('$kind:email:$n')));
    await _repo.logEvent('email', row.id, 'create', after: await _repo.rowOf('email', row.id), batch: batch);
    return row.id;
  }

  Future<String?> _account(String kind, String integrationId, String platformId, DiscoveredAccount a, String batch, SyncSummary s) async {
    final ref = '$kind:account:${a.externalId}';
    final all = await (db.select(db.accounts)..where((t) => t.platformId.equals(platformId))).get();
    Account? hit;
    for (final x in all) {
      if (x.originRef == ref || x.externalId == a.externalId) hit = x;
    }
    if (hit != null) {
      if (hit.deletedAt != null) return null; // the user removed it: respect that
      final ch = <String, Object?>{
        if (hit.integrationId != integrationId) 'integration_id': integrationId,
        if (hit.connectionStatus != 'connected') 'connection_status': 'connected',
        if (hit.originRef != ref) 'origin_ref': ref,
        if (hit.externalId == null) 'external_id': a.externalId,
        if (hit.profileUrl == null && a.profileUrl != null) 'profile_url': a.profileUrl,
      };
      if (ch.isNotEmpty) {
        await _repo.updateFields('account', hit.id, ch, batch: batch);
        s.updated++;
      }
      return hit.id;
    }
    // A manual account with the same username on this platform is adopted, not duplicated.
    if (a.username != null) {
      for (final x in all) {
        if (x.deletedAt == null && x.externalId == null && (x.username ?? '').toLowerCase() == a.username!.toLowerCase()) {
          await _repo.updateFields('account', x.id, {
            'external_id': a.externalId,
            'integration_id': integrationId,
            'connection_status': 'connected',
            'origin_ref': ref,
          }, batch: batch);
          s.adopted++;
          return x.id;
        }
      }
    }
    final row = await db.into(db.accounts).insertReturning(AccountsCompanion.insert(
        platformId: platformId,
        displayName: a.displayName,
        username: Value(a.username),
        profileUrl: Value(a.profileUrl),
        externalId: Value(a.externalId),
        integrationId: Value(integrationId),
        connectionStatus: const Value('connected'),
        origin: const Value('discovered'),
        originRef: Value(ref)));
    await _repo.logEvent('account', row.id, 'create', after: await _repo.rowOf('account', row.id), batch: batch);
    s.added++;
    return row.id;
  }

  Future<String?> _resource(String kind, String platformId, String? accountId, DiscoveredResource d, String batch, SyncSummary s) async {
    final ref = '$kind:resource:${d.externalId}';
    final all = await (db.select(db.resources)..where((t) => t.platformId.equals(platformId))).get();
    Resource? hit;
    for (final x in all) {
      if (x.originRef == ref) hit = x;
    }
    if (hit != null) {
      if (hit.deletedAt != null) return null;
      // Only discovered rows follow the source; manual edits are never overwritten.
      if (hit.origin == 'discovered') {
        final ch = <String, Object?>{
          if (hit.name != d.name) 'name': d.name,
          if (hit.url != d.url && d.url != null) 'url': d.url,
          if (hit.region != d.region && d.region != null) 'region': d.region,
        };
        if (ch.isNotEmpty) {
          await _repo.updateFields('resource', hit.id, ch, batch: batch);
          s.updated++;
        }
      }
      return hit.id;
    }
    for (final x in all) {
      if (x.deletedAt == null && x.originRef == null && x.type == d.type && x.name.toLowerCase() == d.name.toLowerCase()) {
        await _repo.updateFields('resource', x.id, {'origin_ref': ref}, batch: batch);
        s.adopted++;
        return x.id;
      }
    }
    final row = await db.into(db.resources).insertReturning(ResourcesCompanion.insert(
        type: d.type,
        name: d.name,
        platformId: Value(platformId),
        managingAccountId: Value(accountId),
        url: Value(d.url),
        region: Value(d.region),
        origin: const Value('discovered'),
        originRef: Value(ref)));
    await _repo.logEvent('resource', row.id, 'create', after: await _repo.rowOf('resource', row.id), batch: batch);
    s.added++;
    return row.id;
  }

  /// Items that came from this source but are no longer returned are flagged for review,
  /// never deleted (the API may simply lack permission or be eventually consistent).
  Future<void> _flagMissing(String entity, String table, String kind, Set<String> seen, String batch, SyncSummary s) async {
    final rows = await db.customSelect(
        "SELECT id, needs_review AS nr, review_reason AS rr FROM $table WHERE origin_ref LIKE ? AND deleted_at IS NULL",
        variables: [Variable<String>('$kind:$entity:%')]).get();
    for (final r in rows) {
      final id = r.read<String>('id');
      final nr = r.read<int>('nr') == 1;
      final rr = r.readNullable<String>('rr');
      if (seen.contains(id)) {
        if (nr && rr == 'missing_from_source') {
          await _repo.updateFields(entity, id, {'needs_review': 0, 'review_reason': null}, batch: batch);
          s.unflagged++;
        }
      } else if (!nr) {
        await _repo.updateFields(entity, id, {'needs_review': 1, 'review_reason': 'missing_from_source'}, batch: batch);
        s.flagged++;
      }
    }
  }
}
