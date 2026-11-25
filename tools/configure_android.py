"""Run after `flutter create`: target/compile API 36 (Google Play rule since 2026-08-31).
Handles groovy and kotlin DSL. Fails loudly if no pattern matched, so CI shows it."""
import re, pathlib, sys
root = pathlib.Path('android/app')
f = next((p for p in (root/'build.gradle.kts', root/'build.gradle') if p.exists()), None)
if not f: sys.exit('no android/app/build.gradle(.kts) found')
s = f.read_text(); orig = s
s = re.sub(r'targetSdk(Version)?\s*=?\s*flutter\.targetSdkVersion', 'targetSdk = 36', s)
s = re.sub(r'compileSdk(Version)?\s*=?\s*flutter\.compileSdkVersion', 'compileSdk = 36', s)
if s == orig: sys.exit('no target/compile SDK pattern matched: patch manually')
f.write_text(s); print('patched', f)
