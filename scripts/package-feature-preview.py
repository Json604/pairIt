#!/usr/bin/env python3
"""Package only the reviewed feature artifacts; never caches, QA identities or keys."""
import hashlib
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / 'artifacts/feature-preview'
profile = json.loads((ROOT / 'release/google-play/release.json').read_text())
if profile.get('release_stage') != 'feature-preview':
    raise SystemExit('This packager is only for the explicitly gated feature preview.')
name = 'PairIt-' + profile['version_name'] + '-feature-preview'
app_name = 'PairIt-' + profile['version_name']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

android = json.loads((PREVIEW / 'android-release/build-report.json').read_text())
if android['version_code'] != profile['version_code']:
    raise SystemExit('Android candidate does not match release configuration.')
for filename, digest in android['hashes'].items():
    if sha(PREVIEW / 'android-release' / filename) != digest:
        raise SystemExit('Android artifact changed after validation: ' + filename)
debug = json.loads((PREVIEW / 'android/verification.json').read_text())
debug_path = 'artifacts/feature-preview/android/' + app_name + '-preview.apk'
if sha(ROOT / debug_path) != debug['artifacts'][debug_path]:
    raise SystemExit('Debug APK changed after verification.')
mac = json.loads((PREVIEW / 'mac/build-report.json').read_text())
if sha(PREVIEW / 'mac/PairIt.app/Contents/MacOS/AudioRelay') != mac['binary_sha256']:
    raise SystemExit('Mac executable changed after verification.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(PREVIEW / 'mac/PairIt.app')], check=True)
windows = json.loads((PREVIEW / 'windows/windows-verification.json').read_text())
if sha(ROOT / windows['archive']['path']) != windows['archive']['sha256']:
    raise SystemExit('Windows ZIP changed after verification.')
ios = json.loads((PREVIEW / 'ios/build-report.json').read_text())
for application in ios['apps'].values():
    if application['version'] != profile['version_name'] or int(application['build']) != profile['version_code']:
        raise SystemExit('iPhone artifact version does not match the preview.')
    for relative, digest in application['executable_components_sha256'].items():
        if sha(ROOT / application['path'] / relative) != digest:
            raise SystemExit('iPhone executable changed after verification: ' + relative)
    app = ROOT / application['path']
    content = {str(path.relative_to(app)): sha(path) for path in sorted(app.rglob('*')) if path.is_file()}
    digest = hashlib.sha256(json.dumps(content, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if digest != application['bundle_content_sha256']:
        raise SystemExit('iPhone bundle changed after verification: ' + application['path'])

files = [
    'android/' + app_name + '-preview.apk', 'android/verification.json',
    'android-release/' + app_name + '.aab', 'android-release/' + app_name + '-testing.apk',
    'android-release/upload-certificate.pem', 'android-release/build-report.json',
    'android-release/apk-signature.txt', 'android-release/bundle-validation.txt',
    'mac/build-report.json', 'mac/signature-verification.txt',
    'windows/PairIt-Windows-x64-preview.zip', 'windows/windows-verification.json',
    'ios/build-report.json', 'ios/source-audit.json', 'ios/transport-check/results.json',
    'verification/mac-fanout.json', 'verification/mac-gateway.json',
    'ui/verification.json', 'README.md',
]
docs = [
    'release/PUBLISHING-GUIDE.md', 'release/FEATURE-ACCEPTANCE.md', 'release/README.md',
    'engineering/FEATURE-EXPANSION-PLAN.md', 'engineering/FEATURE-EXPANSION-REVIEW.md',
    'engineering/PROTOCOL.md', 'engineering/ANDROID-IMPLEMENTATION.md',
    'engineering/IOS-IMPLEMENTATION.md', 'engineering/MAC-IMPLEMENTATION.md',
    'engineering/MAC-IMPLEMENTATION-REVIEW.md', 'engineering/WINDOWS-IMPLEMENTATION.md',
    'engineering/WINDOWS-IMPLEMENTATION-REVIEW.md',
]
inputs = [(PREVIEW / p, p) for p in files] + [(ROOT / p, 'docs/' + p) for p in docs]
for path, _ in inputs:
    if not path.is_file():
        raise SystemExit('Missing verified handoff file: ' + str(path))

with tempfile.TemporaryDirectory(prefix='pairit-preview-package-') as temporary:
    temporary = Path(temporary)
    for source, filename in [
        ('mac/PairIt.app', 'mac/PairIt-Mac-universal-preview.zip'),
        ('ios/Audio Relay iOS Simulator.app', 'ios/PairIt-iOS-Simulator-preview.zip'),
        ('ios/Audio Relay iOS Unsigned.app', 'ios/PairIt-iOS-Unsigned-preview.zip'),
    ]:
        output = temporary / Path(filename).name
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(PREVIEW / source), str(output)], check=True)
        with zipfile.ZipFile(output) as bundle:
            if bundle.testzip() is not None:
                raise SystemExit('Bundle ZIP failed CRC verification: ' + filename)
            for entry in bundle.namelist():
                if Path(entry).suffix.lower() in {'.p12', '.jks', '.keystore', '.mobileprovision'} or 'credentials' in entry.lower():
                    raise SystemExit('Private material found in bundle: ' + filename)
        inputs.append((output, filename))
    hashes = {relative: sha(path) for path, relative in inputs}
    archive = ROOT / 'artifacts' / (name + '.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for path, relative in inputs:
            output.write(path, name + '/' + relative)
        output.writestr(name + '/SHA256.json', json.dumps(hashes, indent=2) + '\n')
    with zipfile.ZipFile(archive) as output:
        if output.testzip() is not None:
            raise SystemExit('Preview ZIP failed CRC verification.')
        for relative, digest in hashes.items():
            if hashlib.sha256(output.read(name + '/' + relative)).hexdigest() != digest:
                raise SystemExit('Preview ZIP content mismatch: ' + relative)
    report = {'archive': str(archive.relative_to(ROOT)), 'sha256': sha(archive),
              'bytes': archive.stat().st_size, 'files': len(hashes),
              'crc_and_content_hash_verification': 'passed',
              'status': 'feature preview; physical/platform/store gates remain pending'}
    (PREVIEW / 'package-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
