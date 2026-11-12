#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib, json, shutil, subprocess, zipfile
from pathlib import Path
root=Path.cwd(); stage=root/'artifacts/Audio Relay 0.3 Preview'
stage.mkdir(parents=True,exist_ok=True)
items={
 'Audio Relay.app':root/'artifacts/Audio Relay.app',
 'Android/Audio Relay-debug.apk':root/'artifacts/audio-relay-debug.apk',
 'Android/Audio Relay-unsigned.aab':root/'android/build/outputs/bundle/release/AudioRelay-release.aab',
 'iPhone/Audio Relay iOS Simulator.app':root/'artifacts/Audio Relay iOS Simulator.app',
 'iPhone/Audio Relay iOS Unsigned.app':root/'artifacts/Audio Relay iOS Unsigned.app',
 'Release guide.md':root/'release/README.md',
 'Store listing draft.md':root/'release/STORE-COPY.md',
 'Privacy policy draft.md':root/'release/PRIVACY-DRAFT.md',
}
for name,src in items.items():
 if not src.exists(): raise SystemExit(f'Missing build: {src}')
 dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True)
 if src.is_dir(): subprocess.run(['ditto','--norsrc','--noextattr',str(src),str(dest)],check=True)
 else: shutil.copy2(src,dest)
(stage/'START HERE.txt').write_text('Audio Relay 0.3 — development preview\n\nMac: open Audio Relay.app. Use the headphone menu-bar icon.\nAndroid: install the debug APK for local testing; the AAB is unsigned.\niPhone: simulator build and unsigned device build are included. Device installation requires your Apple development team.\n\nUse the source archive for Xcode/Android Studio projects and build scripts.\nThese builds are not store releases. Phone playback and shortcut testing are pending.\nThe known-good audio baseline has been preserved separately.\n')
source=root/'artifacts/Audio Relay 0.3 Source.zip'
folders=['mac','android/src','android/res','android/gradle','apple','ios','release','design']
files=['README.md','TESTPLAN.md','EXPERIMENTS.md','.gitignore','android/AndroidManifest.xml','android/build.gradle','android/settings.gradle','android/gradle.properties','android/gradlew','android/gradlew.bat','scripts/build-mac.sh','scripts/build-driver.sh','scripts/build-android.sh','scripts/build-ios.sh','scripts/generate-ios-project.py','scripts/generate-app-icons.swift','scripts/package-preview.sh','scripts/uninstall-driver.sh']
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as archive:
 paths=[root/f for f in files]
 for folder in folders: paths.extend(p for p in (root/folder).rglob('*') if p.is_file())
 for path in sorted(set(paths)):
  if any(part in ['xcuserdata','__pycache__','.DS_Store'] for part in path.parts):continue
  if path.suffix in ['.jks','.keystore','.p12','.mobileprovision']:continue
  archive.write(path,Path('Audio Relay Source')/path.relative_to(root))
shutil.copy2(source,stage/source.name)
hashes={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(stage.rglob('*')) if p.is_file() and p.name!='SHA256.json'}
(stage/'SHA256.json').write_text(json.dumps(hashes,indent=2)+'\n')
subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(stage),str(root/'artifacts/Audio Relay 0.3 Preview.zip')],check=True)
print('Packaged artifacts/Audio Relay 0.3 Preview.zip')
print('Source projects: artifacts/Audio Relay 0.3 Source.zip')
PY
