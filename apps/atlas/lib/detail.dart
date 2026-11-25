import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'forms.dart';
import 'strings.dart';

class Sec {
  Sec(this.title, this.items, {this.onAdd, this.onRemove, this.onOpen});
  final String title;
  final Stream<List<RelRow>> items;
  final Future<void> Function()? onAdd;
  final Future<void> Function(RelRow)? onRemove;
  final void Function(RelRow)? onOpen;
}

/// Editable columns per entity (all plain text; the first one is required).
const editSpec = <String, List<String>>{
  'platform': ['name', 'base_url', 'category'],
  'account': ['display_name', 'username', 'profile_url'],
  'email': ['address', 'label'],
  'identity': ['name', 'notes'],
  'project': ['name', 'description', 'category', 'status'],
  'resource': ['name', 'url', 'region'],
};

Future<bool> editEntity(BuildContext context, AtlasRepo repo, String entity, String id) async {
  final cols = editSpec[entity];
  if (cols == null) return false;
  final s = S.of(context);
  final row = await repo.rowOf(entity, id);
  if (row == null || !context.mounted) return false;
  final ctl = {for (final c in cols) c: TextEditingController(text: (row[c] ?? '').toString())};
  final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
            title: Text(s.t('edit')),
            content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final k in cols)
                TextField(controller: ctl[k], decoration: InputDecoration(labelText: s.t('f_$k'))),
            ])),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('save'))),
            ],
          ));
  if (ok != true) return false;
  final changes = <String, Object?>{};
  for (final k in cols) {
    final v = ctl[k]!.text.trim();
    final old = (row[k] ?? '').toString();
    if (v == old) continue;
    if (k == cols.first && v.isEmpty) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('required'))));
      return false;
    }
    changes[k] = v.isEmpty ? null : v;
    if (entity == 'email' && k == 'address') changes['address_normalized'] = normalizeEmail(v);
  }
  if (changes.isEmpty) return false;
  await repo.updateFields(entity, id, changes);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('saved'))));
  return true;
}

class EntityPage extends StatelessWidget {
  const EntityPage({super.key, required this.repo, required this.entity, required this.title,
      required this.id, this.subtitle, this.header, required this.sections});
  final AtlasRepo repo;
  final String entity, id, title;
  final String? subtitle;
  final Widget? header;
  final List<Sec> sections;

  Future<void> _delete(BuildContext c) async {
    final s = S.of(c);
    final nav = Navigator.of(c);
    final msg = ScaffoldMessenger.of(c);
    await repo.softDelete(entity, id);
    final last = (await repo.watchActivity(limit: 1).first).first.id;
    nav.pop();
    msg.showSnackBar(SnackBar(
        content: Text(s.t('deleted')),
        action: SnackBarAction(label: s.t('undo'), onPressed: () => repo.undo(last))));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final notes = Sec(s.t('notes'), repo.watchNotes(entity, id),
        onAdd: () async {
          final b = await askOne(context, s.t('note'));
          if (b != null) await repo.addNote(entity, id, b);
        },
        onRemove: (r) => repo.softDelete('note', r.linkId));
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [
        if (editSpec.containsKey(entity))
          IconButton(
              tooltip: s.t('edit'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final nav = Navigator.of(context);
                if (await editEntity(context, repo, entity, id)) nav.pop(); // lists are live streams; reopen to see the new title
              }),
        IconButton(tooltip: s.t('delete'), icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context)),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (subtitle != null) Padding(padding: const EdgeInsets.all(8), child: Text(subtitle!)),
        if (header != null) header!,
        for (final sec in [...sections, notes]) _SecView(sec),
      ]),
    );
  }
}

class _SecView extends StatelessWidget {
  const _SecView(this.sec);
  final Sec sec;
  @override
  Widget build(BuildContext context) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            title: Text(sec.title, style: Theme.of(context).textTheme.titleMedium),
            trailing: sec.onAdd == null ? null : IconButton(icon: const Icon(Icons.add), onPressed: sec.onAdd),
          ),
          StreamBuilder<List<RelRow>>(
            stream: sec.items,
            builder: (c, snap) => Column(children: [
              for (final r in snap.data ?? <RelRow>[])
                ListTile(
                  title: Text(r.label), subtitle: r.sub == null ? null : Text(r.sub!),
                  onTap: sec.onOpen == null ? null : () => sec.onOpen!(r),
                  trailing: sec.onRemove == null ? null
                      : IconButton(icon: const Icon(Icons.link_off), onPressed: () => sec.onRemove!(r)),
                ),
            ]),
          ),
        ]),
      );
}

// ------------------------------------------------------------------ openers
Future<void> openEntity(BuildContext context, AtlasRepo repo, String type, String id) async {
  final nav = Navigator.of(context);
  final db = repo.db;
  Widget? page;
  switch (type) {
    case 'platform':
      final x = await (db.select(db.platforms)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = platformPage(repo, x);
    case 'account':
      final x = await (db.select(db.accounts)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = accountPage(repo, x);
    case 'email':
      final x = await (db.select(db.emails)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = emailPage(repo, x);
    case 'identity':
      final x = await (db.select(db.identities)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = identityPage(repo, x);
    case 'project':
      final x = await (db.select(db.projects)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = projectPage(repo, x);
    case 'resource':
      final x = await (db.select(db.resources)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (x != null) page = resourcePage(repo, x);
  }
  if (page != null) nav.push(MaterialPageRoute(builder: (_) => page!));
}

Future<String?> _pick(BuildContext c, String title, Map<String, String> options) async {
  if (options.isEmpty) return null;
  final r = await askForm(c, title, [F.pick('v', title, options)]);
  return r?['v'];
}

Widget platformPage(AtlasRepo r, Platform x) => Builder(builder: (c) => EntityPage(
    repo: r, entity: 'platform', id: x.id, title: x.name, subtitle: x.baseUrl,
    sections: [Sec(S.of(c).t('accounts'), r.platformAccountRels(x.id),
        onOpen: (rel) => openEntity(c, r, 'account', rel.otherId))]));

Widget emailPage(AtlasRepo r, Email x) => Builder(builder: (c) => EntityPage(
    repo: r, entity: 'email', id: x.id, title: x.address,
    sections: [Sec(S.of(c).t('accounts'), r.emailAccountRels(x.id),
        onOpen: (rel) => openEntity(c, r, 'account', rel.otherId),
        onRemove: (rel) => r.softDelete('account_email', rel.linkId))]));

Widget accountPage(AtlasRepo r, Account x) => Builder(builder: (c) {
      final s = S.of(c);
      return EntityPage(
        repo: r, entity: 'account', id: x.id, title: x.displayName, subtitle: x.username,
        header: _IdentityPicker(repo: r, account: x),
        sections: [
          Sec(s.t('emails'), r.accountEmailRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkEmail'),
                    {for (final e in await r.watchEmails().first) e.id: e.address});
                if (id != null) await r.linkAccountEmailOnce(x.id, id);
              },
              onOpen: (rel) => openEntity(c, r, 'email', rel.otherId),
              onRemove: (rel) => r.softDelete('account_email', rel.linkId)),
          Sec(s.t('projects'), r.accountProjectRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkProject'),
                    {for (final p in await r.watchProjects().first) p.id: p.name});
                if (id != null) await r.linkProjectAccount(id, x.id);
              },
              onOpen: (rel) => openEntity(c, r, 'project', rel.otherId),
              onRemove: (rel) => r.softDelete('project_account', rel.linkId)),
        ],
      );
    });

class _IdentityPicker extends StatefulWidget {
  const _IdentityPicker({required this.repo, required this.account});
  final AtlasRepo repo;
  final Account account;
  @override
  State<_IdentityPicker> createState() => _IdentityPickerState();
}

class _IdentityPickerState extends State<_IdentityPicker> {
  late String? value = widget.account.identityId;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return StreamBuilder<List<Identity>>(
      stream: widget.repo.watchIdentities(),
      builder: (c, snap) => Padding(
        padding: const EdgeInsets.all(8),
        child: DropdownButtonFormField<String?>(
          initialValue: value,
          decoration: InputDecoration(labelText: s.t('identity')),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(s.t('noIdentity'))),
            for (final i in snap.data ?? <Identity>[]) DropdownMenuItem(value: i.id, child: Text(i.name)),
          ],
          onChanged: (v) async {
            setState(() => value = v);
            await widget.repo.setAccountIdentity(widget.account.id, v);
          },
        ),
      ),
    );
  }
}

Widget identityPage(AtlasRepo r, Identity x) => Builder(builder: (c) {
      final s = S.of(c);
      return EntityPage(
        repo: r, entity: 'identity', id: x.id, title: x.name, subtitle: x.notes,
        sections: [
          Sec(s.t('emails'), r.identityEmailRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkEmail'),
                    {for (final e in await r.watchEmails().first) e.id: e.address});
                if (id != null) await r.linkIdentityEmail(x.id, id);
              },
              onOpen: (rel) => openEntity(c, r, 'email', rel.otherId),
              onRemove: (rel) => r.softDelete('identity_email', rel.linkId)),
          Sec(s.t('accounts'), r.identityAccountRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkAccount'),
                    {for (final a in await r.watchAccounts().first) a.id: a.displayName});
                if (id != null) await r.setAccountIdentity(id, x.id);
              },
              onOpen: (rel) => openEntity(c, r, 'account', rel.otherId),
              onRemove: (rel) => r.setAccountIdentity(rel.otherId, null)),
        ],
      );
    });

Widget projectPage(AtlasRepo r, Project x) => Builder(builder: (c) {
      final s = S.of(c);
      return EntityPage(
        repo: r, entity: 'project', id: x.id, title: x.name, subtitle: x.description,
        sections: [
          Sec(s.t('accounts'), r.projectAccountRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkAccount'),
                    {for (final a in await r.watchAccounts().first) a.id: a.displayName});
                if (id != null) await r.linkProjectAccount(x.id, id);
              },
              onOpen: (rel) => openEntity(c, r, 'account', rel.otherId),
              onRemove: (rel) => r.softDelete('project_account', rel.linkId)),
          Sec(s.t('resources'), r.projectResourceRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkResource'),
                    {for (final e in await r.watchResources().first) e.id: e.name});
                if (id != null) await r.linkProjectResource(x.id, id);
              },
              onOpen: (rel) => openEntity(c, r, 'resource', rel.otherId),
              onRemove: (rel) => r.softDelete('project_resource', rel.linkId)),
        ],
      );
    });

Widget resourcePage(AtlasRepo r, Resource x) => Builder(builder: (c) {
      final s = S.of(c);
      return EntityPage(
        repo: r, entity: 'resource', id: x.id, title: x.name, subtitle: s.t('t_${x.type}'),
        sections: [
          Sec(s.t('projects'), r.resourceProjectRels(x.id),
              onAdd: () async {
                final id = await _pick(c, s.t('linkProject'),
                    {for (final p in await r.watchProjects().first) p.id: p.name});
                if (id != null) await r.linkProjectResource(id, x.id);
              },
              onOpen: (rel) => openEntity(c, r, 'project', rel.otherId),
              onRemove: (rel) => r.softDelete('project_resource', rel.linkId)),
        ],
      );
    });
