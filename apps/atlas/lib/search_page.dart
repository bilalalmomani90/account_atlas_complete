import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'detail.dart';
import 'strings.dart';

IconData iconForType(String t) => switch (t) {
      'platform' => Icons.public, 'account' => Icons.person, 'email' => Icons.email,
      'identity' => Icons.badge, 'project' => Icons.folder, 'resource' => Icons.storage,
      _ => Icons.circle,
    };

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  Future<List<SearchHit>> results = Future.value(const []);
  String q = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          autofocus: true,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: s.t('searchHint'),
              border: const OutlineInputBorder()),
          onChanged: (v) => setState(() { q = v; results = widget.repo.search(v); }),
        ),
      ),
      Expanded(child: FutureBuilder<List<SearchHit>>(
        future: results,
        builder: (c, snap) {
          final hits = snap.data ?? const <SearchHit>[];
          if (q.trim().isNotEmpty && hits.isEmpty && snap.connectionState == ConnectionState.done) {
            return Center(child: Text(s.t('noResults')));
          }
          return ListView(children: [
            for (final h in hits)
              ListTile(
                leading: Icon(iconForType(h.type)), title: Text(h.title),
                subtitle: h.sub == null ? null : Text(h.sub!),
                onTap: () => openEntity(context, widget.repo, h.type, h.id),
              ),
          ]);
        },
      )),
    ]);
  }
}
