#!/usr/bin/env python3
"""Package the verified Play candidate and public assets, never signing secrets."""
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
profile = json.loads((ROOT / 'release/google-play/release.json').read_text())
if profile.get('release_stage') == 'feature-preview':
    raise SystemExit('This historical packager cannot certify feature previews; prepare current artifacts and verification records as described in README.md.')
name = 'PairIt-' + profile['version_name']
stage = ROOT / 'artifacts' / (name + '-Google-Play')
required = [name + '.aab', name + '-testing.apk', 'upload-certificate.pem', 'build-report.json']
for item in required:
    if not (stage / item).is_file():
        raise SystemExit('Missing release artifact: ' + item)
report = json.loads((stage / 'build-report.json').read_text())
if report['version_code'] != profile['version_code']:
    raise SystemExit('Rebuild the candidate before packaging: version code changed')
for item, expected in report['hashes'].items():
    if hashlib.sha256((stage / item).read_bytes()).hexdigest() != expected:
        raise SystemExit('Release artifact changed after verification: ' + item)
source = ROOT / 'release/google-play'
for directory in ['graphics', 'screenshots', 'listing', 'engineering']:
    shutil.copytree(source / directory, stage / directory, dirs_exist_ok=True)
for item in source.iterdir():
    if item.is_file() and item.suffix in {'.md', '.json'}:
        shutil.copy2(item, stage / item.name)
files = sorted(p for p in stage.rglob('*') if p.is_file() and p.name != 'SHA256.json')
if any(p.suffix in {'.p12', '.keystore', '.jks', '.mobileprovision'} or 'credentials' in p.name for p in files):
    raise SystemExit('Private signing material must never be packaged')
checksums = {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(stage / 'SHA256.json').write_text(json.dumps(checksums, indent=2) + '\n')
archive = stage.parent / (stage.name + '.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
    for item in sorted(stage.rglob('*')):
        if item.is_file():
            output.write(item, Path(stage.name) / item.relative_to(stage))
print(archive)
