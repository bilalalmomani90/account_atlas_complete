import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'detail.dart';
import 'strings.dart';

const _types = ['identity', 'email', 'account', 'platform', 'project', 'resource'];
const _typeKey = {'identity': 'identities', 'email': 'emails', 'account': 'accounts',
  'platform': 'platforms', 'project': 'projects', 'resource': 'resources'};
const _colors = {
  'identity': Colors.purple, 'email': Colors.orange, 'account': Colors.blue,
  'platform': Colors.teal, 'project': Colors.green, 'resource': Colors.brown,
};

class GraphPage extends StatefulWidget {
  const GraphPage({super.key, required this.repo});
  final AtlasRepo repo;
  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  AtlasGraph? full;
  String? focus;
  int depth = 2;
  final Set<String> types = {..._types};
  String? selected;
  String? _layoutKey;
  AtlasGraph? _sub;
  Map<String, Pt> _pos = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final g = await widget.repo.buildGraph();
    String? best;
    for (final k in g.nodes.keys) {
      if (best == null || g.degree(k) > g.degree(best)) best = k;
    }
    if (mounted) setState(() { full = g; focus = focus != null && g.nodes.containsKey(focus) ? focus : best; selected = null; });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = full;
    if (g == null) return const Center(child: CircularProgressIndicator());
    if (g.nodes.isEmpty || focus == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(s.t('empty')), TextButton(onPressed: _load, child: Text(s.t('reload'))),
      ]));
    }
    final key = '$focus|$depth|${(types.toList()..sort()).join(',')}|${g.nodes.length}|${g.edges.length}';
    if (key != _layoutKey) {
      _sub = g.neighborhood(focus!, depth, types: types);
      _pos = forceLayout(_sub!);
      _layoutKey = key;
    }
    final sub = _sub!;
    final pos = _pos;
    final sel = selected == null ? null : sub.nodes[selected];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final t in _types)
            FilterChip(
              label: Text(s.t(_typeKey[t]!)), selected: types.contains(t),
              onSelected: (v) => setState(() => v ? types.add(t) : types.remove(t)),
            ),
          Text(s.t('depth')),
          SegmentedButton<int>(
            segments: const [ButtonSegment(value: 1, label: Text('1')), ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 3, label: Text('3'))],
            selected: {depth}, onSelectionChanged: (v) => setState(() => depth = v.first),
          ),
          IconButton(tooltip: s.t('reload'), onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
      ),
      Expanded(child: InteractiveViewer(
        boundaryMargin: const EdgeInsets.all(300), minScale: 0.3, maxScale: 4,
        child: GestureDetector(
          onTapUp: (d) {
            String? hit;
            var best = 28.0;
            for (final e in pos.entries) {
              final dist = (Offset(e.value.x, e.value.y) - d.localPosition).distance;
              if (dist < best) { best = dist; hit = e.key; }
            }
            setState(() => selected = hit);
          },
          child: CustomPaint(
            size: const Size(1000, 1000),
            painter: _GraphPainter(sub, pos, focus!, selected, Theme.of(context).colorScheme.onSurface),
          ),
        ),
      )),
      if (sel != null) ListTile(
        leading: Icon(Icons.circle, color: _colors[sel.type]),
        title: Text(sel.label), subtitle: Text(s.t(_typeKey[sel.type] ?? 'name')),
        trailing: Wrap(children: [
          TextButton(onPressed: () => setState(() => focus = sel.key), child: Text(s.t('focus'))),
          TextButton(onPressed: () => openEntity(context, widget.repo, sel.type, sel.id), child: Text(s.t('open'))),
        ]),
      ),
    ]);
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.g, this.pos, this.focus, this.selected, this.textColor);
  final AtlasGraph g;
  final Map<String, Pt> pos;
  final String focus;
  final String? selected;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = textColor.withValues(alpha: 0.25)..strokeWidth = 1.5;
    for (final e in g.edges) {
      final a = pos[e.from], b = pos[e.to];
      if (a != null && b != null) canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), line);
    }
    for (final n in g.nodes.values) {
      final p = pos[n.key]!;
      final r = n.key == focus ? 14.0 : 9.0;
      canvas.drawCircle(Offset(p.x, p.y), r, Paint()..color = _colors[n.type] ?? Colors.grey);
      if (n.key == selected) {
        canvas.drawCircle(Offset(p.x, p.y), r + 4,
            Paint()..color = textColor..style = PaintingStyle.stroke..strokeWidth = 2);
      }
      final rtl = RegExp(r'[؀-ۿ]').hasMatch(n.label);
      final tp = TextPainter(
        text: TextSpan(text: n.label, style: TextStyle(color: textColor, fontSize: 11)),
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        maxLines: 1, ellipsis: '…',
      )..layout(maxWidth: 110);
      tp.paint(canvas, Offset(p.x - tp.width / 2, p.y + r + 2));
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
