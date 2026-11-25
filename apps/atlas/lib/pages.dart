import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'activity_page.dart';
import 'data_page.dart';
import 'detail.dart';
import 'forms.dart';
import 'graph_page.dart';
import 'search_page.dart';
import 'integrations_page.dart';
import 'audit_page.dart';
import 'security.dart';
import 'strings.dart';
import 'sync_page.dart';

const resourceTypes = ['database', 'hosting', 'domain', 'storage', 'api', 'subscription', 'custom'];

class Shell extends StatefulWidget {
  const Shell({super.key, required this.repo, required this.integrations, required this.onTheme, required this.onLang});
  final AtlasRepo repo;
  final IntegrationService integrations;
  final VoidCallback onTheme, onLang;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;
  static const _keys = ['dashboard', 'platforms', 'accounts', 'emails', 'identities',
    'projects', 'resources', 'search', 'graph', 'activity', 'data', 'integrations', 'syncNav', 'security', 'audit'];
  static const _icons = [Icons.dashboard, Icons.public, Icons.person, Icons.email, Icons.badge,
    Icons.folder, Icons.storage, Icons.search, Icons.hub, Icons.history, Icons.import_export, Icons.cable, Icons.sync_alt, Icons.shield, Icons.fact_check];
  static const _noFab = {0, 7, 8, 9, 10, 11, 12, 13, 14};

  Widget _page() {
    final r = widget.repo;
    Widget l<T>(Stream<List<T>> st, String type, String Function(T) id, Widget Function(T) tile) =>
        _list<T>(st, (x) => tile(x), (x) => openEntity(context, r, type, id(x)));
    switch (index) {
      case 0: return DashboardPage(repo: r);
      case 1: return l<Platform>(r.watchPlatforms(), 'platform', (x) => x.id, (x) => ListTile(title: Text(x.name), subtitle: x.baseUrl == null ? null : Text(x.baseUrl!)));
      case 2: return l<Account>(r.watchAccounts(), 'account', (x) => x.id, (x) => ListTile(title: Text(x.displayName), subtitle: x.username == null ? null : Text(x.username!)));
      case 3: return l<Email>(r.watchEmails(), 'email', (x) => x.id, (x) => ListTile(title: Text(x.address)));
      case 4: return l<Identity>(r.watchIdentities(), 'identity', (x) => x.id, (x) => ListTile(title: Text(x.name)));
      case 5: return l<Project>(r.watchProjects(), 'project', (x) => x.id, (x) => ListTile(title: Text(x.name), subtitle: Text(x.status)));
      case 6: return l<Resource>(r.watchResources(), 'resource', (x) => x.id, (x) => ListTile(title: Text(x.name), subtitle: Text(S.of(context).t('t_${x.type}'))));
      case 7: return SearchPage(repo: r);
      case 8: return GraphPage(repo: r);
      case 9: return ActivityPage(repo: r);
      case 10: return DataPage(repo: r);
      case 11: return IntegrationsPage(repo: r, service: widget.integrations);
      case 12: return SyncPage(repo: r);
      case 13: return const SecurityPage();
      default: return AuditPage(repo: r);
    }
  }

  Widget _list<T>(Stream<List<T>> stream, Widget Function(T) tile, void Function(T) onTap) =>
      StreamBuilder<List<T>>(
        stream: stream,
        builder: (c, snap) {
          final items = snap.data ?? <T>[];
          if (items.isEmpty) return Center(child: Text(S.of(c).t('empty')));
          return ListView(children: [
            for (final x in items) InkWell(onTap: () => onTap(x), child: IgnorePointer(child: tile(x))),
          ]);
        },
      );

  Future<void> _add() async {
    final c = context;
    final s = S.of(c);
    final r = widget.repo;
    switch (index) {
      case 1:
        final n = await askOne(c, s.t('name'));
        if (n != null) await r.addPlatform(n);
      case 2:
        final ps = await r.watchPlatforms().first;
        if (!c.mounted) return;
        if (ps.isEmpty) { _snack(s.t('needPlatform')); return; }
        final res = await askForm(c, s.t('accounts'), [
          F.pick('platform', s.t('platform'), {for (final p in ps) p.id: p.name}),
          F.text('name', s.t('name')), F.text('user', s.t('username'), optional: true),
        ]);
        if (res != null) await r.addAccount(platformId: res['platform']!, displayName: res['name']!, username: res['user']);
      case 3:
        final a = await askOne(c, s.t('address'));
        if (a != null) await r.addEmail(a);
      case 4:
        final n = await askOne(c, s.t('name'));
        if (n != null) await r.addIdentity(n);
      case 5:
        final n = await askOne(c, s.t('name'));
        if (n != null) await r.addProject(n);
      case 6:
        final res = await askForm(c, s.t('resources'), [
          F.pick('type', s.t('type'), {for (final t in resourceTypes) t: s.t('t_$t')}),
          F.text('name', s.t('name')),
        ]);
        if (res != null) await r.addResource(res['type']!, res['name']!);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final wide = MediaQuery.of(context).size.width >= 800;
    final nav = [for (var i = 0; i < _keys.length; i++) (s.t(_keys[i]), _icons[i])];
    return Scaffold(
      appBar: AppBar(title: Text(s.t(_keys[index])), actions: [
        TextButton(onPressed: widget.onLang, child: Text(s.t('lang'))),
        IconButton(tooltip: s.t('theme'), onPressed: widget.onTheme, icon: const Icon(Icons.brightness_6)),
      ]),
      drawer: wide ? null : Drawer(child: ListView(children: [
        for (var i = 0; i < nav.length; i++)
          ListTile(leading: Icon(nav[i].$2), title: Text(nav[i].$1), selected: i == index,
              onTap: () { setState(() => index = i); Navigator.pop(context); }),
      ])),
      body: Row(children: [
        if (wide) SingleChildScrollView(child: IntrinsicHeight(child: NavigationRail(
          extended: true, selectedIndex: index,
          onDestinationSelected: (i) => setState(() => index = i),
          destinations: [for (final n in nav) NavigationRailDestination(icon: Icon(n.$2), label: Text(n.$1))],
        ))),
        Expanded(child: _page()),
      ]),
      floatingActionButton: _noFab.contains(index) ? null : FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.repo});
  final AtlasRepo repo;

  Widget _count(String label, Stream<List<Object?>> st) => StreamBuilder<List<Object?>>(
        stream: st,
        builder: (c, s) => Card(child: SizedBox(width: 150, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.data?.length ?? 0}', style: Theme.of(c).textTheme.headlineMedium),
            Text(label),
          ]),
        ))),
      );

  Widget _accounts(BuildContext c, Stream<List<Account>> st) => StreamBuilder<List<Account>>(
        stream: st,
        builder: (c, sn) => Column(children: [
          for (final a in sn.data ?? <Account>[])
            ListTile(title: Text(a.displayName), onTap: () => openEntity(c, repo, 'account', a.id)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        _count(s.t('platforms'), repo.watchPlatforms()),
        _count(s.t('accounts'), repo.watchAccounts()),
        _count(s.t('identities'), repo.watchIdentities()),
        _count(s.t('projects'), repo.watchProjects()),
        _count(s.t('resources'), repo.watchResources()),
        _count(s.t('emails'), repo.watchEmails()),
      ]),
      const SizedBox(height: 24),
      Text(s.t('recent'), style: Theme.of(context).textTheme.titleMedium),
      _accounts(context, repo.watchRecentAccounts()),
      const SizedBox(height: 16),
      Text(s.t('incomplete'), style: Theme.of(context).textTheme.titleMedium),
      _accounts(context, repo.watchAccountsMissingEmail()),
      const SizedBox(height: 16),
      Text(s.t('sync')),
    ]);
  }
}
