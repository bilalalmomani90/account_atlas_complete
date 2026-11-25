import 'dart:async';
import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'integrations_page.dart';
import 'strings.dart';

const _store = SecureSecretStore();
const _pinKey = 'app_pin_hash';

/// Shows the PIN screen before [child] when a PIN is set; re-locks after the app was in the
/// background for [grace]. The PIN only gates the UI. The database is encrypted separately
/// with a random key held by the OS secure store.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child, this.grace = const Duration(seconds: 30)});
  final Widget child;
  final Duration grace;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  bool _ready = false, _locked = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.read(_pinKey).then((v) {
      if (mounted) setState(() { _ready = true; _locked = v != null; });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left != null && DateTime.now().difference(left) >= widget.grace && await _store.read(_pinKey) != null) {
        if (mounted) setState(() => _locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Stack(children: [
      widget.child,
      if (_locked) Positioned.fill(child: _PinScreen(onUnlock: () => setState(() => _locked = false))),
    ]);
  }
}

class _PinScreen extends StatefulWidget {
  const _PinScreen({required this.onUnlock});
  final VoidCallback onUnlock;
  @override
  State<_PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<_PinScreen> {
  final ctl = TextEditingController();
  int failures = 0, wait = 0;
  bool wrong = false;
  Timer? t;

  Future<void> _try() async {
    if (wait > 0) return;
    final stored = await _store.read(_pinKey);
    if (stored == null || await verifyPin(ctl.text, stored)) return widget.onUnlock();
    failures++;
    ctl.clear();
    setState(() { wrong = true; wait = pinDelaySeconds(failures); });
    t?.cancel();
    if (wait > 0) {
      t = Timer.periodic(const Duration(seconds: 1), (x) {
        if (!mounted) return x.cancel();
        setState(() => wait--);
        if (wait <= 0) x.cancel();
      });
    }
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock, size: 48),
              const SizedBox(height: 16),
              Text(s.t('lk_enter')),
              const SizedBox(height: 12),
              TextField(
                controller: ctl, obscureText: true, autofocus: true, keyboardType: TextInputType.number,
                textAlign: TextAlign.center, onSubmitted: (_) => _try(), enabled: wait == 0,
                decoration: InputDecoration(errorText: wrong ? (wait > 0 ? '${s.t('lk_wait')} $wait' : s.t('lk_wrong')) : null),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: wait == 0 ? _try : null, child: Text(s.t('lk_unlock'))),
            ]),
          ),
        ),
      ),
    );
  }
}

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  bool? hasPin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _store.read(_pinKey);
    if (mounted) setState(() => hasPin = v != null);
  }

  Future<String?> _ask(String label) {
    final ctl = TextEditingController();
    final s = S.of(context);
    return showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(label),
              content: TextField(controller: ctl, obscureText: true, autofocus: true, keyboardType: TextInputType.number),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
                FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(s.t('save'))),
              ],
            ));
  }

  Future<void> _set() async {
    final s = S.of(context);
    final a = await _ask(s.t('lk_new'));
    if (a == null || !mounted) return;
    if (a.length < 4) return _snack(s.t('lk_short'));
    final b = await _ask(s.t('lk_repeat'));
    if (b == null) return;
    if (a != b) return _snack(s.t('lk_mismatch'));
    await _store.write(_pinKey, await hashPin(a));
    await _load();
    _snack(s.t('lk_saved'));
  }

  Future<void> _remove() async {
    final s = S.of(context);
    final stored = await _store.read(_pinKey);
    final cur = await _ask(s.t('lk_enter'));
    if (cur == null || stored == null) return;
    if (!await verifyPin(cur, stored)) return _snack(s.t('lk_wrong'));
    await _store.delete(_pinKey);
    await _load();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
          child: ListTile(
        leading: Icon(hasPin == true ? Icons.lock : Icons.lock_open),
        title: Text(s.t('lk_title')),
        subtitle: Text(hasPin == true ? s.t('lk_on') : s.t('lk_off')),
        trailing: hasPin == null
            ? null
            : Wrap(children: [
                TextButton(onPressed: _set, child: Text(hasPin! ? s.t('lk_change') : s.t('lk_enable'))),
                if (hasPin!) TextButton(onPressed: _remove, child: Text(s.t('lk_disable'))),
              ]),
      )),
      Padding(padding: const EdgeInsets.all(8), child: Text(s.t('lk_note'), style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}
