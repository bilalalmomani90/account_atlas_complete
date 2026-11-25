"""Run after configure_android.py. Makes the release build use android/key.properties
(written by CI from secrets). Handles Kotlin DSL and Groovy. Fails loudly if the
generated template does not match, so CI shows it instead of silently signing with the debug key."""
import pathlib, sys
root = pathlib.Path('android/app')
kts, gr = root/'build.gradle.kts', root/'build.gradle'
if kts.exists():
    f, s = kts, kts.read_text()
    if 'keystoreProperties' in s: sys.exit('already patched')
    head = ('val keystoreProperties = java.util.Properties().apply {\n'
            '    val f = rootProject.file("key.properties")\n'
            '    if (f.exists()) load(f.inputStream())\n}\n\n')
    signing = ('    signingConfigs {\n        create("release") {\n'
               '            keyAlias = keystoreProperties["keyAlias"] as String\n'
               '            keyPassword = keystoreProperties["keyPassword"] as String\n'
               '            storeFile = file(keystoreProperties["storeFile"] as String)\n'
               '            storePassword = keystoreProperties["storePassword"] as String\n        }\n    }\n\n')
    old_cfg = 'signingConfigs.getByName("debug")'; new_cfg = 'signingConfigs.getByName("release")'
elif gr.exists():
    f, s = gr, gr.read_text()
    if 'keystoreProperties' in s: sys.exit('already patched')
    head = ('def keystoreProperties = new Properties()\n'
            'def keystorePropertiesFile = rootProject.file("key.properties")\n'
            'if (keystorePropertiesFile.exists()) { keystoreProperties.load(new FileInputStream(keystorePropertiesFile)) }\n\n')
    signing = ('    signingConfigs {\n        release {\n'
               '            keyAlias keystoreProperties["keyAlias"]\n'
               '            keyPassword keystoreProperties["keyPassword"]\n'
               '            storeFile keystoreProperties["storeFile"] ? file(keystoreProperties["storeFile"]) : null\n'
               '            storePassword keystoreProperties["storePassword"]\n        }\n    }\n\n')
    old_cfg = 'signingConfigs.debug'; new_cfg = 'signingConfigs.release'
else:
    sys.exit('no android/app/build.gradle(.kts) found')
if old_cfg not in s or 'buildTypes {' not in s:
    sys.exit('release signing pattern not found: patch ' + str(f) + ' manually')
if '\nandroid {' not in s:
    sys.exit('android { block not found: patch ' + str(f) + ' manually')
# plugins {} must stay the first block in Kotlin DSL, so the helper goes right before android {
s = s.replace('\nandroid {', '\n' + head + 'android {', 1)
s = s.replace('    buildTypes {', signing + '    buildTypes {', 1).replace(old_cfg, new_cfg, 1)
f.write_text(s); print('patched', f)
