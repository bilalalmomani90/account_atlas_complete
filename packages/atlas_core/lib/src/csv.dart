/// RFC 4180-style CSV: quotes, escaped quotes, newlines in fields, BOM, auto delimiter.
List<List<String>> parseCsv(String text, {String? delimiter}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final d = delimiter ?? _detect(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var inQ = false, any = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQ) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') { f.write('"'); i++; } else { inQ = false; }
      } else { f.write(c); }
    } else if (c == '"') { inQ = true; any = true; }
    else if (c == d) { row.add(f.toString()); f.clear(); any = true; }
    else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(f.toString()); f.clear();
      if (any || row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[]; any = false;
    } else { f.write(c); any = true; }
  }
  if (any || f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
  return rows;
}

String _detect(String t) {
  final line = t.split(RegExp(r'[\r\n]')).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  var best = ',', n = -1;
  for (final d in [',', ';', '\t']) {
    final c = d.allMatches(line).length;
    if (c > n) { n = c; best = d; }
  }
  return best;
}

String toCsv(List<List<Object?>> rows) {
  String q(Object? v) {
    final s = v == null ? '' : '$v';
    return s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }
  // BOM so Excel opens Arabic correctly.
  return '﻿${rows.map((r) => r.map(q).join(',')).join('\r\n')}\r\n';
}
