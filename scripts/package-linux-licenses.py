#!/usr/bin/env python3
"""Bundle dependency license notices from the restored Linux package graph."""
import json
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET
cache, output = map(Path, sys.argv[1:])
lock = json.loads((Path(__file__).resolve().parent.parent / 'linux/PairIt.Linux/packages.lock.json').read_text())
packages = {}
for group in lock['dependencies'].values():
    for name, info in group.items():
        if info.get('type') != 'Project': packages[name] = info['resolved']
lines = ['PairIt Linux dependency notices', '']
for name, version in sorted(packages.items()):
    folder = cache / name.lower() / version
    nuspec = next(folder.glob('*.nuspec'))
    root = ET.parse(nuspec).getroot()
    metadata = next(e for e in root if e.tag.endswith('metadata'))
    license_node = next((e for e in metadata if e.tag.endswith('license')), None)
    notice = license_node.text if license_node is not None else 'See upstream package license.'
    lines.append(f'{name} {version}: {notice}')
    for source in folder.iterdir():
        if source.is_file() and any(word in source.name.upper() for word in ('LICENSE', 'NOTICE', 'COPYING')):
            shutil.copy2(source, output / (name + '-' + source.name))
    if license_node is not None and license_node.get('type') == 'file':
        source = folder / license_node.text
        if not source.resolve().is_relative_to(folder.resolve()): raise ValueError('Unsafe license path')
        shutil.copy2(source, output / (name + '-' + source.name))
(output / 'dependencies.txt').write_text('\n'.join(lines) + '\n')

for source in (Path(__file__).resolve().parent.parent / 'linux/licenses').glob('*.txt'):
    shutil.copy2(source, output / source.name)
for folder in cache.glob('microsoft.netcore.app.runtime.linux-*/*'):
    for source in folder.glob('*.TXT'):
        shutil.copy2(source, output / ('dotnet-' + source.name))
