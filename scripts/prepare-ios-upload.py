#!/usr/bin/env python3
"""Copy an unsigned archive and normalize embedded framework signing identities.

Xcode then applies the actual distribution signature during export. Preserve the
input archive. This does not create credentials, upload, or certify the app.
"""
import argparse
import plistlib
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = args.archive.resolve()
destination = args.output.resolve()
if not (source / 'Info.plist').is_file() or not (source / 'Products/Applications').is_dir():
    parser.error('Input must be a completed Xcode app archive')
if destination.exists():
    parser.error('Output already exists; preserve it and choose a new output path')
if source == destination or source in destination.parents:
    parser.error('Output must be outside the input archive')
shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
frameworks = sorted(destination.glob('Products/Applications/**/*.framework'), key=lambda p: len(p.parts), reverse=True)
for framework in frameworks:
    with (framework / 'Info.plist').open('rb') as stream:
        identifier = plistlib.load(stream)['CFBundleIdentifier']
    if not re.fullmatch(r'[A-Za-z0-9.-]+', identifier):
        raise SystemExit('Invalid embedded framework bundle identifier')
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', identifier, str(framework)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', '-R', f'=identifier "{identifier}"', str(framework)], check=True)
print(f'Prepared {destination.name}: verified {len(frameworks)} embedded framework identities. Export with Xcode distribution signing next.')
