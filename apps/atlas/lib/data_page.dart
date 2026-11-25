import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'io_helpers.dart';
import 'strings.dart';

String _stamp() => DateTime.now().toIso8601String().split('T').first;

void _msg(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<void> _alert(BuildContext c, String title, String body) => showDialog<void>(
    context: c,
    builder: (_) => AlertDialog(title: Text(title), content: SingleChildScrollView(child: Text(body)),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));

class DataPage extends StatefulWidget {
  const DataPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  String csvEntity = 'accounts';

  Future<void> _exportJson() async {
    final s = S.of(context);
    final path = await saveTextFile('account-atlas-${_stamp()}.json', await widget.repo.exportJson());
    if (mounted && path != null) _msg(context, '${s.t('savedTo')} $path');
  }

  Future<void> _exportCsv() async {
    final s = S.of(context);
    final path = await saveTextFile('$csvEntity-${_stamp()}.csv', await widget.repo.exportCsv(csvEntity));
    if (mounted && path != null) _msg(context, '${s.t('savedTo')} $path');
  }

  Future<String?> _askPw(String label) {
    final s = S.of(context);
    final ctl = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(label),
              content: TextField(controller: ctl, obscureText: true, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(s.t('save'))),
              ],
            ));
  }

  Future<void> _exportEncrypted() async {
    final s = S.of(context);
    final pw = await _askPw(s.t('bk_pw'));
    if (pw == null || pw.length < 8 || !mounted) return;
    final env = await widget.repo.exportEncrypted(pw);
    final path = await saveTextFile('account-atlas-${_stamp()}.atlasbak', env);
    if (!mounted || path == null) return;
    // A backup is only a backup once it decrypts and matches the live data.
    final check = await widget.repo.verifyEncrypted(env, pw);
    _msg(context, check.ok ? '${s.t('bk_ok')}: $path' : s.t('bk_bad'));
  }

  Future<void> _import() async {
    final s = S.of(context);
    final f = await pickTextFile();
    if (f == null || !mounted) return;
    final nav = Navigator.of(context);
    try {
      if (isEncrypted(f.$2)) {
        final pw = await _askPw(s.t('bk_askpw'));
        if (pw == null) return;
        final plan = await widget.repo.planEncryptedRestore(f.$2, pw);
        nav.push(MaterialPageRoute(builder: (_) => ImportPreviewPage(repo: widget.repo, plan: plan)));
      } else if (f.$1.toLowerCase().endsWith('.json')) {
        final plan = await widget.repo.planBackup(f.$2, source: f.$1);
        nav.push(MaterialPageRoute(builder: (_) => ImportPreviewPage(repo: widget.repo, plan: plan)));
      } else {
        nav.push(MaterialPageRoute(builder: (_) => CsvMappingPage(repo: widget.repo, name: f.$1, text: f.$2)));
      }
    } on BadPassword {
      if (mounted) _alert(context, s.t('badFile'), s.t('bk_wrongpw'));
    } on FormatException catch (e) {
      if (mounted) _alert(context, s.t('badFile'), e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FilledButton.icon(onPressed: _exportJson, icon: const Icon(Icons.download), label: Text(s.t('exportJson'))),
        const SizedBox(height: 8),
        Text(s.t('exportWarn'), style: Theme.of(context).textTheme.bodySmall),
      ]))),
      Card(child: ListTile(leading: const Icon(Icons.enhanced_encryption), title: Text(s.t('bk_enc')), onTap: _exportEncrypted)),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
        Expanded(child: DropdownButtonFormField<String>(
          initialValue: csvEntity,
          items: [for (final e in csvFields.keys) DropdownMenuItem(value: e, child: Text(s.t(e)))],
          onChanged: (v) => setState(() => csvEntity = v ?? csvEntity),
        )),
        const SizedBox(width: 12),
        OutlinedButton.icon(onPressed: _exportCsv, icon: const Icon(Icons.table_chart), label: Text(s.t('exportCsv'))),
      ]))),
      Card(child: ListTile(leading: const Icon(Icons.upload_file), title: Text(s.t('importFile')), onTap: _import)),
      Card(child: ListTile(
        leading: const Icon(Icons.content_copy), title: Text(s.t('findDups')),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DuplicatesPage(repo: widget.repo))),
      )),
    ]);
  }
}

// ---------------------------------------------------------------- CSV mapping
class CsvMappingPage extends StatefulWidget {
  const CsvMappingPage({super.key, required this.repo, required this.name, required this.text});
  final AtlasRepo repo;
  final String name, text;
  @override
  State<CsvMappingPage> createState() => _CsvMappingPageState();
}

class _CsvMappingPageState extends State<CsvMappingPage> {
  late final table = parseCsv(widget.text);
  String entity = 'accounts';
  late Map<String, int> mapping = guessMapping(entity, table.isEmpty ? [] : table.first);

  Future<void> _preview() async {
    final s = S.of(context);
    final nav = Navigator.of(context);
    try {
      final plan = await widget.repo.planCsv(entity, table, mapping, source: widget.name);
      nav.push(MaterialPageRoute(builder: (_) => ImportPreviewPage(repo: widget.repo, plan: plan)));
    } on FormatException catch (e) {
      if (mounted) _alert(context, s.t('badFile'), e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final headers = table.isEmpty ? <String>[] : table.first;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('mapFields'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          initialValue: entity, decoration: InputDecoration(labelText: s.t('target')),
          items: [for (final e in csvFields.keys) DropdownMenuItem(value: e, child: Text(s.t(e)))],
          onChanged: (v) => setState(() { entity = v!; mapping = guessMapping(entity, headers); }),
        ),
        const SizedBox(height: 12),
        for (final f in csvFields[entity]!)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: DropdownButtonFormField<int?>(
            key: ValueKey('$entity-${f.$1}-${mapping[f.$1]}'),
            initialValue: mapping[f.$1],
            decoration: InputDecoration(labelText: '${f.$1}${f.$2 ? ' *' : ''}'),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(s.t('notMapped'))),
              for (var i = 0; i < headers.length; i++) DropdownMenuItem<int?>(value: i, child: Text(headers[i])),
            ],
            onChanged: (v) => setState(() { if (v == null) { mapping.remove(f.$1); } else { mapping[f.$1] = v; } }),
          )),
        FilledButton(onPressed: _preview, child: Text(s.t('preview'))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- preview + apply
class ImportPreviewPage extends StatefulWidget {
  const ImportPreviewPage({super.key, required this.repo, required this.plan});
  final AtlasRepo repo;
  final ImportPlan plan;
  @override
  State<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends State<ImportPreviewPage> {
  bool busy = false;

  List<Decision> _options(ImportStatus st) => switch (st) {
        ImportStatus.add => [Decision.add, Decision.skip],
        ImportStatus.duplicate => [Decision.skip, Decision.add, Decision.merge],
        ImportStatus.changed => [Decision.skip, Decision.replace],
        _ => const [],
      };

  int _n(Decision d) => widget.plan.items.where((i) => i.status != ImportStatus.same && i.decision == d).length;

  Future<void> _apply() async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s.t('confirm')),
        content: Text('${s.t('d_add')}: ${_n(Decision.add)}\n${s.t('d_replace')}: ${_n(Decision.replace)}\n'
            '${s.t('d_merge')}: ${_n(Decision.merge)}\n${s.t('d_skip')}: ${_n(Decision.skip)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('apply'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      final res = await widget.repo.applyImport(widget.plan);
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (c) => AlertDialog(
        title: Text(s.t('done')),
        content: SingleChildScrollView(child: Text(
            '${s.t('added')}: ${res.added}\n${s.t('replaced')}: ${res.replaced}\n${s.t('merged')}: ${res.merged}\n'
            '${s.t('skipped')}: ${res.skipped}\n${s.t('alreadyThere')}: ${res.alreadyThere}'
            '${res.errors.isEmpty ? '' : '\n\n${s.t('errors')}:\n${res.errors.join('\n')}'}')),
        actions: [
          TextButton(onPressed: () async { await widget.repo.undoBatch(res.batchId); if (c.mounted) Navigator.pop(c); },
              child: Text(s.t('undoImport'))),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ));
      if (mounted) Navigator.pop(context);
    } on StateError catch (e) {
      if (mounted) _alert(context, s.t('errors'), e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final plan = widget.plan;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('preview'))),
      body: ListView(children: [
        Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, children: [
          for (final st in ImportStatus.values)
            if (plan.count(st) > 0) Chip(label: Text('${s.t('st_${st.name}')}: ${plan.count(st)}')),
        ])),
        if (plan.warnings.isNotEmpty) ExpansionTile(
          title: Text('${s.t('warnings')} (${plan.warnings.length})'),
          children: [for (final w in plan.warnings) ListTile(dense: true, title: Text(w))]),
        for (final it in plan.items.where((i) => i.status != ImportStatus.same))
          ListTile(
            dense: true,
            title: Text(it.label ?? it.id),
            subtitle: Text('${it.table} · ${s.t('st_${it.status.name}')}${it.note == null ? '' : ' · ${it.note}'}'),
            trailing: _options(it.status).isEmpty ? null : DropdownButton<Decision>(
              value: it.decision,
              items: [for (final d in _options(it.status)) DropdownMenuItem(value: d, child: Text(s.t('d_${d.name}')))],
              onChanged: (d) => setState(() => it.decision = d!),
            ),
          ),
      ]),
      bottomNavigationBar: SafeArea(child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton(onPressed: busy ? null : _apply, child: Text(s.t('apply'))),
      )),
    );
  }
}

// ---------------------------------------------------------------- duplicates
class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  late Future<List<DupGroup>> groups = widget.repo.findDuplicates();
  final keep = <DupGroup, int>{};

  Future<void> _merge(DupGroup g) async {
    final s = S.of(context);
    final k = keep[g] ?? 0;
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(s.t('merge')), content: Text(s.t('mergeConfirm')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('merge'))),
      ]));
    if (ok != true || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    try {
      final batches = <String>[];
      for (var i = 0; i < g.ids.length; i++) {
        if (i != k) batches.add(await widget.repo.mergeEntities(g.entity, g.ids[k], g.ids[i]));
      }
      msg.showSnackBar(SnackBar(content: Text(s.t('done')), action: SnackBarAction(
          label: s.t('undo'), onPressed: () async { for (final b in batches.reversed) { await widget.repo.undoBatch(b); } })));
      setState(() => groups = widget.repo.findDuplicates());
    } on StateError catch (e) {
      if (mounted) _alert(context, s.t('errors'), e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('findDups'))),
      body: FutureBuilder<List<DupGroup>>(
        future: groups,
        builder: (c, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (snap.data!.isEmpty) return Center(child: Text(s.t('noDups')));
          return ListView(children: [
            for (final g in snap.data!)
              Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.t('${g.entity}s')} · ${g.reason}', style: Theme.of(c).textTheme.labelMedium),
                RadioGroup<int>(
                  groupValue: keep[g] ?? 0,
                  onChanged: (v) => setState(() => keep[g] = v ?? 0),
                  child: Column(children: [
                    for (var i = 0; i < g.ids.length; i++)
                      RadioListTile<int>(value: i, title: Text(g.labels[i]), subtitle: Text(s.t('keep'))),
                  ]),
                ),
                Align(alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton(onPressed: () => _merge(g), child: Text(s.t('merge')))),
              ]))),
          ]);
        },
      ),
    );
  }
}
