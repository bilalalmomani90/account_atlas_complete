import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'detail.dart';
import 'strings.dart';

const _order = ['needs_review', 'renewal_soon', 'account_no_email', 'account_stale', 'account_no_identity',
  'email_unused', 'platform_empty', 'project_empty', 'resource_orphan'];

class AuditPage extends StatefulWidget {
  const AuditPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  late Future<List<AuditIssue>> f = widget.repo.audit();
  void _reload() => setState(() => f = widget.repo.audit());

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return FutureBuilder<List<AuditIssue>>(
      future: f,
      builder: (c, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final all = snap.data!;
        return ListView(padding: const EdgeInsets.all(12), children: [
          Row(children: [
            Expanded(child: Text(s.t('au_intro'), style: Theme.of(c).textTheme.bodySmall)),
            IconButton(tooltip: s.t('reload'), onPressed: _reload, icon: const Icon(Icons.refresh)),
          ]),
          if (all.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s.t('au_clean')))),
          for (final k in _order)
            if (all.any((i) => i.kind == k))
              Card(
                child: ExpansionTile(
                  initiallyExpanded: k == 'needs_review',
                  title: Text('${s.t('au_$k')} (${all.where((i) => i.kind == k).length})'),
                  children: [
                    for (final i in all.where((i) => i.kind == k))
                      ListTile(
                        dense: true,
                        title: Text(i.label),
                        subtitle: i.detail == null ? null : Text(i.detail!),
                        onTap: () async {
                          await openEntity(context, widget.repo, i.entity, i.id);
                          _reload();
                        },
                        trailing: k == 'account_stale'
                            ? TextButton(
                                onPressed: () async {
                                  await widget.repo.markReviewed(i.id);
                                  _reload();
                                },
                                child: Text(s.t('au_reviewed')))
                            : null,
                      ),
                  ],
                ),
              ),
        ]);
      },
    );
  }
}
