import 'dart:async';
import 'package:atlas_core/atlas_core.dart';
import 'package:drift/drift.dart' show OrderingTerm, CustomExpression;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'strings.dart';

/// Tokens go to the OS secure store only; the database keeps a pointer.
class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this._s = const FlutterSecureStorage()]);
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String ref) => _s.read(key: ref);
  @override
  Future<void> write(String ref, String value) => _s.write(key: ref, value: value);
  @override
  Future<void> delete(String ref) => _s.delete(key: ref);
}

IntegrationService buildIntegrations(AtlasDatabase db) {
  final http = IoHttp();
  return IntegrationService(db, const SecureSecretStore(), {
    'github': GithubProvider(http),
    'supabase': SupabaseProvider(http),
    'firebase': FirebaseProvider(http),
  });
}

const _kinds = ['github', 'supabase', 'firebase'];
const _icons = {'github': Icons.code, 'supabase': Icons.bolt, 'firebase': Icons.local_fire_department};

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key, required this.repo, required this.service});
  final AtlasRepo repo;
  final IntegrationService service;
  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  final _busy = <String>{};
  AtlasDatabase get db => widget.repo.db;

  void _msg(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  String _err(IntegrationException e) {
    final s = S.of(context);
    switch (e.kind) {
      case 'auth': return s.t('i_authErr');
      case 'rate_limited':
        final at = e.retryAt;
        return '${s.t('i_rateErr')}${at == null ? '' : ' (${TimeOfDay.fromDateTime(at).format(context)})'}';
      case 'network': return s.t('i_netErr');
      default: return s.t('i_apiErr');
    }
  }

  Future<void> _sync(String id) async {
    final s = S.of(context);
    setState(() => _busy.add(id));
    try {
      final r = await widget.service.sync(id);
      if (mounted) {
        final extra = r.notes.map((n) => s.t('n_$n')).join(' ');
        _msg('${s.t('i_done')}: +${r.added} ~${r.updated} ⇄${r.adopted} ⚑${r.flagged} $extra');
      }
    } on IntegrationException catch (e) {
      if (mounted) _msg(_err(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _connect(String kind) async {
    final s = S.of(context);
    String? method = 'token';
    if (kind == 'github') {
      method = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(title: Text(s.t('i_method')), children: [
                SimpleDialogOption(onPressed: () => Navigator.pop(c, 'token'), child: Text(s.t('i_pat'))),
                SimpleDialogOption(onPressed: () => Navigator.pop(c, 'device'), child: Text(s.t('i_device'))),
              ]));
      if (method == null) return;
    }
    String? token;
    var authType = 'pat';
    if (method == 'device') {
      token = await _deviceFlow();
      authType = 'oauth_device';
    } else {
      token = await _askToken(kind);
      authType = kind == 'firebase' ? 'oauth_token' : 'pat';
    }
    if (token == null || token.trim().isEmpty) return;
    final id = await widget.service.connect(kind, authType, token.trim(),
        scopes: kind == 'github' ? 'read:user user:email' : null);
    await _sync(id);
  }

  Future<String?> _askToken(String kind) {
    final s = S.of(context);
    final ctl = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(s.t('i_token')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(s.t('i_hint_$kind')),
                const SizedBox(height: 8),
                TextField(controller: ctl, obscureText: true, autocorrect: false, enableSuggestions: false,
                    decoration: InputDecoration(labelText: s.t('i_token'))),
                const SizedBox(height: 8),
                Text(s.t('i_secureNote'), style: Theme.of(c).textTheme.bodySmall),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(s.t('save'))),
              ],
            ));
  }

  Future<String?> _deviceFlow() async {
    final s = S.of(context);
    final ctl = TextEditingController();
    final cid = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(s.t('i_device')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(s.t('i_clientHelp')),
                TextField(controller: ctl, decoration: const InputDecoration(labelText: 'Client ID')),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(s.t('confirm'))),
              ],
            ));
    if (cid == null || cid.isEmpty) return null;
    final flow = GithubDeviceFlow(IoHttp(), cid);
    try {
      final code = await flow.start();
      var cancelled = false;
      if (!mounted) return null;
      unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
                title: Text(s.t('i_enterCode')),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  SelectableText(code.userCode, style: Theme.of(c).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  SelectableText(code.verificationUri),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Clipboard.setData(ClipboardData(text: code.userCode)),
                      child: Text(s.t('copy'))),
                  TextButton(
                      onPressed: () {
                        cancelled = true;
                        Navigator.pop(c);
                      },
                      child: Text(s.t('cancel'))),
                ],
              )));
      try {
        final t = await flow.poll(code, cancelled: () => cancelled);
        if (mounted && !cancelled) Navigator.of(context, rootNavigator: true).pop();
        return t;
      } on IntegrationException catch (e) {
        if (mounted && !cancelled) Navigator.of(context, rootNavigator: true).pop();
        if (mounted && !cancelled) _msg(_err(e));
        return null;
      }
    } on IntegrationException catch (e) {
      if (mounted) _msg(_err(e));
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return StreamBuilder<List<Integration>>(
      stream: widget.service.watchIntegrations(),
      builder: (c, snap) {
        final rows = snap.data ?? const <Integration>[];
        return ListView(padding: const EdgeInsets.all(12), children: [
          Text(s.t('i_intro'), style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final k in _kinds) ...[
            _card(k, rows.where((r) => r.kind == k).cast<Integration?>().firstWhere((_) => true, orElse: () => null)),
          ],
          const Divider(height: 32),
          Text(s.t('i_review'), style: Theme.of(c).textTheme.titleMedium),
          _Review(repo: widget.repo),
          const Divider(height: 32),
          Text(s.t('i_history'), style: Theme.of(c).textTheme.titleMedium),
          _History(db: db),
        ]);
      },
    );
  }

  Widget _card(String kind, Integration? i) {
    final s = S.of(context);
    final connected = i != null && i.status != 'disconnected';
    final busy = i != null && _busy.contains(i.id);
    return Card(
      child: ListTile(
        leading: Icon(_icons[kind]),
        title: Text(s.t('k_$kind')),
        subtitle: Text(connected
            ? '${s.t('s_${i.status}')}${i.lastSyncAt == null ? '' : ' · ${i.lastSyncAt!.toLocal().toString().split('.').first}'}'
            : s.t('s_disconnected')),
        trailing: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Wrap(children: [
                if (connected) ...[
                  IconButton(tooltip: s.t('i_sync'), icon: const Icon(Icons.sync), onPressed: () => _sync(i.id)),
                  IconButton(
                      tooltip: s.t('i_disconnect'),
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        await widget.service.disconnect(i.id);
                        if (mounted) _msg(s.t('i_disconnected'));
                      }),
                ] else
                  FilledButton(onPressed: () => _connect(kind), child: Text(s.t('i_connect'))),
              ]),
      ),
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({required this.repo});
  final AtlasRepo repo;

  @override
  Widget build(BuildContext context) {
    final db = repo.db;
    final s = S.of(context);
    return StreamBuilder<List<(String, String, String)>>(
      stream: db
          .customSelect(
              "SELECT 'account' AS e, id, display_name AS n FROM accounts WHERE needs_review = 1 AND deleted_at IS NULL "
              "UNION ALL SELECT 'resource', id, name FROM resources WHERE needs_review = 1 AND deleted_at IS NULL",
              readsFrom: {db.accounts, db.resources})
          .watch()
          .map((rs) => [for (final r in rs) (r.read<String>('e'), r.read<String>('id'), r.read<String>('n'))]),
      builder: (c, snap) {
        final items = snap.data ?? const [];
        if (items.isEmpty) return Padding(padding: const EdgeInsets.all(8), child: Text(s.t('i_noReview')));
        return Column(children: [
          for (final (e, id, n) in items)
            ListTile(
              dense: true,
              title: Text(n),
              subtitle: Text('${s.t(e == 'account' ? 'accounts' : 'resources')} · ${s.t('i_missing')}'),
              trailing: Wrap(children: [
                TextButton(
                    onPressed: () => repo.updateFields(e, id, {'needs_review': 0, 'review_reason': null}),
                    child: Text(s.t('keep'))),
                TextButton(onPressed: () => repo.softDelete(e, id), child: Text(s.t('delete'))),
              ]),
            ),
        ]);
      },
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.db});
  final AtlasDatabase db;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return StreamBuilder<List<SyncHistoryData>>(
      stream: (db.select(db.syncHistory)
            ..orderBy([(t) => OrderingTerm.desc(CustomExpression<int>('rowid'))])
            ..limit(10))
          .watch(),
      builder: (c, snap) {
        final rows = snap.data ?? const <SyncHistoryData>[];
        if (rows.isEmpty) return Padding(padding: const EdgeInsets.all(8), child: Text(s.t('empty')));
        return Column(children: [
          for (final h in rows)
            ListTile(
              dense: true,
              leading: Icon(h.result == 'ok' ? Icons.check_circle : Icons.error_outline),
              title: Text(h.source.replaceFirst('integration:', '')),
              subtitle: Text('${h.startedAt.toLocal().toString().split('.').first}  ${h.counts ?? h.error ?? ''}'),
            ),
        ]);
      },
    );
  }
}
