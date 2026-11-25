import 'dart:math';
import 'repositories.dart';

class GNode {
  GNode(this.type, this.id, this.label);
  final String type, id, label;
  String get key => '$type:$id';
}

class GEdge {
  GEdge(this.from, this.to, this.kind);
  final String from, to, kind; // node keys
}

class Pt {
  Pt(this.x, this.y);
  double x, y;
}

class AtlasGraph {
  AtlasGraph(this.nodes, this.edges);
  final Map<String, GNode> nodes;
  final List<GEdge> edges;

  int degree(String key) => edges.where((e) => e.from == key || e.to == key).length;

  /// Sub-graph within [depth] hops of [focus] (progressive display keeps big graphs usable).
  AtlasGraph neighborhood(String focus, int depth, {Set<String>? types}) {
    final seen = <String>{focus};
    var frontier = {focus};
    for (var d = 0; d < depth; d++) {
      final next = <String>{};
      for (final e in edges) {
        if (frontier.contains(e.from) && !seen.contains(e.to)) next.add(e.to);
        if (frontier.contains(e.to) && !seen.contains(e.from)) next.add(e.from);
      }
      next.removeWhere((k) => types != null && !types.contains(nodes[k]!.type));
      seen.addAll(next);
      frontier = next;
    }
    return AtlasGraph({for (final k in seen) k: nodes[k]!},
        [for (final e in edges) if (seen.contains(e.from) && seen.contains(e.to)) e]);
  }
}

/// Deterministic Fruchterman-Reingold layout in a [size] x [size] square.
Map<String, Pt> forceLayout(AtlasGraph g, {double size = 1000, int iterations = 150}) {
  final keys = g.nodes.keys.toList();
  final n = keys.length;
  final pos = <String, Pt>{};
  for (var i = 0; i < n; i++) {
    final a = 2 * pi * i / max(n, 1);
    pos[keys[i]] = Pt(size / 2 + cos(a) * size / 3, size / 2 + sin(a) * size / 3);
  }
  if (n < 2) return pos;
  final k = sqrt(size * size / n) * 0.8;
  var t = size / 8;
  for (var it = 0; it < iterations; it++) {
    final disp = {for (final key in keys) key: Pt(0, 0)};
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var dx = pos[keys[i]]!.x - pos[keys[j]]!.x, dy = pos[keys[i]]!.y - pos[keys[j]]!.y;
        var d = sqrt(dx * dx + dy * dy);
        if (d < 0.01) { dx = 0.01 * (i + 1); dy = 0.01 * (j + 1); d = sqrt(dx * dx + dy * dy); }
        final f = k * k / d;
        disp[keys[i]]!..x += dx / d * f..y += dy / d * f;
        disp[keys[j]]!..x -= dx / d * f..y -= dy / d * f;
      }
    }
    for (final e in g.edges) {
      final a = pos[e.from], b = pos[e.to];
      if (a == null || b == null) continue;
      final dx = a.x - b.x, dy = a.y - b.y;
      final d = max(sqrt(dx * dx + dy * dy), 0.01);
      final f = d * d / k;
      disp[e.from]!..x -= dx / d * f..y -= dy / d * f;
      disp[e.to]!..x += dx / d * f..y += dy / d * f;
    }
    for (final key in keys) {
      final d = disp[key]!;
      final len = max(sqrt(d.x * d.x + d.y * d.y), 0.01);
      final p = pos[key]!;
      p.x = (p.x + d.x / len * min(len, t)).clamp(20, size - 20).toDouble();
      p.y = (p.y + d.y / len * min(len, t)).clamp(20, size - 20).toDouble();
    }
    t *= 0.97;
  }
  return pos;
}

extension AtlasGraphBuild on AtlasRepo {
  Future<AtlasGraph> buildGraph() async {
    final nodes = <String, GNode>{};
    void add(String type, String id, String label) => nodes['$type:$id'] = GNode(type, id, label);
    for (final x in await (db.select(db.platforms)..where((t) => t.deletedAt.isNull())).get()) { add('platform', x.id, x.name); }
    for (final x in await (db.select(db.identities)..where((t) => t.deletedAt.isNull())).get()) { add('identity', x.id, x.name); }
    for (final x in await (db.select(db.emails)..where((t) => t.deletedAt.isNull())).get()) { add('email', x.id, x.address); }
    for (final x in await (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get()) { add('account', x.id, x.displayName); }
    for (final x in await (db.select(db.projects)..where((t) => t.deletedAt.isNull())).get()) { add('project', x.id, x.name); }
    for (final x in await (db.select(db.resources)..where((t) => t.deletedAt.isNull())).get()) { add('resource', x.id, x.name); }

    final edges = <GEdge>[];
    void edge(String ft, String f, String tt, String t, String kind) {
      final a = '$ft:$f', b = '$tt:$t';
      if (nodes.containsKey(a) && nodes.containsKey(b)) edges.add(GEdge(a, b, kind));
    }
    for (final a in await (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get()) {
      edge('account', a.id, 'platform', a.platformId, 'on');
      if (a.identityId != null) edge('identity', a.identityId!, 'account', a.id, 'owns');
    }
    for (final x in await (db.select(db.identityEmails)..where((t) => t.deletedAt.isNull())).get()) {
      edge('identity', x.identityId, 'email', x.emailId, 'uses');
    }
    for (final x in await (db.select(db.accountEmails)..where((t) => t.deletedAt.isNull())).get()) {
      edge('email', x.emailId, 'account', x.accountId, x.role);
    }
    for (final x in await (db.select(db.projectAccounts)..where((t) => t.deletedAt.isNull())).get()) {
      edge('account', x.accountId, 'project', x.projectId, x.role);
    }
    for (final x in await (db.select(db.projectResources)..where((t) => t.deletedAt.isNull())).get()) {
      edge('project', x.projectId, 'resource', x.resourceId, 'has');
    }
    for (final r in await (db.select(db.resources)..where((t) => t.deletedAt.isNull())).get()) {
      if (r.managingAccountId != null) edge('account', r.managingAccountId!, 'resource', r.id, 'manages');
      if (r.platformId != null) edge('resource', r.id, 'platform', r.platformId!, 'hosted_on');
    }
    for (final c in await (db.select(db.connections)..where((t) => t.deletedAt.isNull())).get()) {
      edge(c.fromType, c.fromId, c.toType, c.toId, c.kind);
    }
    return AtlasGraph(nodes, edges);
  }
}
