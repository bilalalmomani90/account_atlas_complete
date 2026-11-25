import 'dart:io';
import 'package:atlas_core/atlas_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'integrations_page.dart';
import 'strings.dart';

const _store = SecureSecretStore();

/// Optional sync through a shared folder. No account, no server.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  String? dir, pw, device;
  bool busy = false, loaded = false;
  SyncReport? last;
  List<ActivityLogData> conflicts = const [];

  FolderSync get _sync => FolderSync(widget.repo, deviceId: device!);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    dir = await _store.read('sync_dir');
    pw = await _store.read('sync_pw');
    device = await _store.read('sync_device');
    if (device == null) {
      device = FolderSync.newDeviceId();
      await _store.write('sync_device', device!);
    }
    final c = await _sync.conflicts();
    if (mounted) setState(() { conflicts = c; loaded = true; });
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    await _store.write('sync_dir', d);
    setState(() => dir = d);
  }

  Future<void> _setPw() async {
    final s = S.of(context);
    final ctl = TextEditingController();
    final v = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(s.t('sy_password')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(s.t('sy_pwNote')),
                TextField(controller: ctl, obscureText: true, autofocus: true),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(s.t('save'))),
              ],
            ));
    if (v == null || v.length < 8) {
      if (v != null) _snack(s.t('sy_pwShort'));
      return;
    }
    await _store.write('sync_pw', v);
    setState(() => pw = v);
  }

  Future<void> _run() async {
    final s = S.of(context);
    setState(() => busy = true);
    try {
      final r = await _sync.run(Directory(dir!), pw!);
      last = r;
      conflicts = await _sync.conflicts();
      _snack(r.problems.isEmpty ? s.t('sy_done') : r.problems.join('\n'));
    } on FileSystemException {
      _snack(s.t('sy_folderErr'));
    } catch (_) {
      _snack(s.t('sy_failed'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (!loaded) return const Center(child: CircularProgressIndicator());
    final ready = dir != null && pw != null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(s.t('sy_intro'), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      Card(child: ListTile(leading: const Icon(Icons.folder_shared), title: Text(s.t('sy_folder')),
          subtitle: Text(dir ?? s.t('sy_none')), trailing: TextButton(onPressed: _pickDir, child: Text(s.t('sy_choose'))))),
      Card(child: ListTile(leading: const Icon(Icons.key), title: Text(s.t('sy_password')),
          subtitle: Text(pw == null ? s.t('sy_none') : '••••••••'), trailing: TextButton(onPressed: _setPw, child: Text(s.t('sy_set'))))),
      const SizedBox(height: 8),
      FilledButton.icon(
          onPressed: ready && !busy ? _run : null,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
          label: Text(s.t('sy_now'))),
      if (last != null) Padding(padding: const EdgeInsets.all(8), child: Text(
          '+${last!.inserted}  ~${last!.updated}  ⚡${last!.conflicts}  ${s.t('skipped')} ${last!.skipped}')),
      const Divider(height: 32),
      Text(s.t('sy_conflicts'), style: Theme.of(context).textTheme.titleMedium),
      if (conflicts.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(s.t('sy_noConflicts'))),
      for (final c in conflicts) _ConflictTile(c: c, onResolve: (other) async {
        await _sync.resolveConflict(c.id, useOther: other);
        final n = await _sync.conflicts();
        if (mounted) setState(() => conflicts = n);
      }),
    ]);
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({required this.c, required this.onResolve});
  final ActivityLogData c;
  final void Function(bool useOther) onResolve;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    String pick(String? j) {
      if (j == null) return '';
      final m = RegExp(r'"(name|display_name|address|type)":"([^"]*)"').firstMatch(j);
      return m?.group(2) ?? '';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c.entityType} · ${c.createdAt.toLocal().toString().split('.').first}'),
          Text('${s.t('sy_current')}: ${pick(c.afterJson)}'),
          Text('${s.t('sy_other')}: ${pick(c.beforeJson)}'),
          Wrap(children: [
            TextButton(onPressed: () => onResolve(false), child: Text(s.t('sy_keepCurrent'))),
            TextButton(onPressed: () => onResolve(true), child: Text(s.t('sy_useOther'))),
          ]),
        ]),
      ),
    );
  }
}
