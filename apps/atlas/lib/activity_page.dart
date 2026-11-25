import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'strings.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return StreamBuilder<List<ActivityLogData>>(
      stream: repo.watchActivity(),
      builder: (c, snap) {
        final rows = snap.data ?? const <ActivityLogData>[];
        if (rows.isEmpty) return Center(child: Text(s.t('empty')));
        return ListView(children: [
          for (final l in rows)
            ListTile(
              title: Text('${s.t('a_${l.action}')} · ${l.entityType}'),
              subtitle: Text(l.createdAt.toLocal().toString().split('.').first),
              trailing: l.undoable && const {'create', 'update', 'delete'}.contains(l.action)
                  ? TextButton(onPressed: () => repo.undo(l.id), child: Text(s.t('undo')))
                  : null,
            ),
        ]);
      },
    );
  }
}
