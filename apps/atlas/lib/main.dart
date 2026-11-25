import 'dart:io';
import 'dart:math';
import 'package:atlas_core/atlas_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'integrations_page.dart';
import 'pages.dart';
import 'security.dart';
import 'strings.dart';

Future<AtlasDatabase> _open() async {
  const store = FlutterSecureStorage();
  var key = await store.read(key: 'db_key');
  if (key == null) {
    final r = Random.secure();
    key = List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await store.write(key: 'db_key', value: key);
  }
  final dir = await getApplicationSupportDirectory();
  return AtlasDatabase(openEncrypted(File(p.join(dir.path, 'atlas.db')), key));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AtlasApp(db: await _open()));
}

class AtlasApp extends StatefulWidget {
  const AtlasApp({super.key, required this.db});
  final AtlasDatabase db;
  @override
  State<AtlasApp> createState() => _AtlasAppState();
}

class _AtlasAppState extends State<AtlasApp> {
  ThemeMode mode = ThemeMode.system;
  Locale locale = const Locale('ar');
  late final integrations = buildIntegrations(widget.db);

  @override
  Widget build(BuildContext context) => MaterialApp(
        locale: locale,
        supportedLocales: S.supported,
        localizationsDelegates: const [
          S.delegate, GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
        ],
        themeMode: mode,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: LockGate(child: Shell(
          repo: AtlasRepo(widget.db),
          integrations: integrations,
          onTheme: () => setState(() =>
              mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark),
          onLang: () => setState(() =>
              locale = locale.languageCode == 'ar' ? const Locale('en') : const Locale('ar')),
        )),
      );
}
