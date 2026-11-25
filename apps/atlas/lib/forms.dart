import 'package:flutter/material.dart';
import 'strings.dart';

class F {
  F.text(this.key, this.label, {this.optional = false}) : options = null;
  F.pick(this.key, this.label, Map<String, String> this.options) : optional = false;
  final String key, label;
  final bool optional;
  final Map<String, String>? options;
}

Future<String?> askOne(BuildContext c, String label) async =>
    (await askForm(c, label, [F.text('v', label)]))?['v'];

Future<Map<String, String>?> askForm(BuildContext c, String title, List<F> fields) {
  final s = S.of(c);
  final ctl = {for (final f in fields) f.key: TextEditingController(text: f.options?.keys.first ?? '')};
  return showDialog<Map<String, String>>(
    context: c,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final f in fields)
          f.options == null
              ? TextField(controller: ctl[f.key], decoration: InputDecoration(labelText: f.label))
              : DropdownButtonFormField<String>(
                  initialValue: ctl[f.key]!.text,
                  decoration: InputDecoration(labelText: f.label),
                  items: [for (final e in f.options!.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => ctl[f.key]!.text = v ?? ''),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            final out = {for (final f in fields) f.key: ctl[f.key]!.text.trim()};
            final ok = fields.every((f) => f.optional || out[f.key]!.isNotEmpty);
            if (ok) Navigator.pop(ctx, {for (final e in out.entries) if (e.value.isNotEmpty) e.key: e.value});
          },
          child: Text(s.t('save'))),
      ],
    )),
  );
}
