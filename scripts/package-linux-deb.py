#!/usr/bin/env python3
"""Build a dependency-aware Ubuntu/Debian installer from a self-contained publish folder."""
import argparse
import io
import json
from pathlib import Path
import re
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
DEPENDENCIES = ('ca-certificates, tzdata, libc6 (>= 2.35), libgcc-s1, libstdc++6, zlib1g, libssl3 | libssl3t64, '
                'libicu70 | libicu72 | libicu74 | libicu76 | libicu78, '
                'libx11-6, libice6, libsm6, libfontconfig1, libfreetype6, '
                'pulseaudio-utils, xdg-utils')
DESKTOP = '''[Desktop Entry]
Type=Application
Name=PairIt - AudioRelay
Comment=Computer audio through your phone
Exec=/opt/pairit/PairIt
Icon=pairit
Terminal=false
Categories=AudioVideo;Audio;
StartupNotify=true
'''


def tar_bytes(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz', format=tarfile.PAX_FORMAT) as archive:
        directories = sorted({str(parent) for name, _, _ in files for parent in Path(name).parents if str(parent) != '.'}, key=lambda value: (value.count('/'), value))
        for directory in directories:
            info = tarfile.TarInfo('./' + directory + '/')
            info.type = tarfile.DIRTYPE; info.mode = 0o755; info.uid = info.gid = 0
            info.uname = info.gname = 'root'; info.mtime = 0
            archive.addfile(info)
        for name, content, mode in files:
            info = tarfile.TarInfo('./' + name)
            info.size = len(content); info.mode = mode; info.uid = info.gid = 0
            info.uname = info.gname = 'root'; info.mtime = 0
            archive.addfile(info, io.BytesIO(content))
    return data.getvalue()


def ar_member(name, data):
    header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'.encode('ascii')
    return header + data + (b'\n' if len(data) % 2 else b'')


def package(publish, architecture, version, destination):
    if architecture not in ('amd64', 'arm64') or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        raise ValueError('Invalid package architecture or version')
    if not (publish / 'PairIt').is_file() or not (publish / 'PairIt.dll').is_file():
        raise ValueError('Expected complete self-contained PairIt publish folder')
    metadata = json.loads((publish / 'PairIt.deps.json').read_text())
    expected_rid = 'linux-x64' if architecture == 'amd64' else 'linux-arm64'
    if 'PairIt/' + version not in metadata.get('libraries', {}) or not metadata.get('runtimeTarget', {}).get('name', '').endswith('/' + expected_rid):
        raise ValueError('Published binary version/architecture does not match package metadata')
    files = []
    for path in sorted(publish.rglob('*')):
        if path.is_symlink():
            raise ValueError('Unexpected symlink in publish folder')
        if path.is_file():
            mode = 0o755 if path.name == 'PairIt' or path.suffix == '.sh' else 0o644
            files.append(('opt/pairit/' + path.relative_to(publish).as_posix(), path.read_bytes(), mode))
    files.extend([
        ('usr/share/applications/pairit.desktop', DESKTOP.encode(), 0o644),
        ('usr/share/icons/hicolor/1024x1024/apps/pairit.png', (ROOT / 'design/PlayStoreIcon.png').read_bytes(), 0o644),
        ('usr/share/doc/pairit/copyright', (ROOT / 'LICENSE').read_bytes(), 0o644),
    ])
    installed_kib = (sum(len(content) for _, content, _ in files) + 1023) // 1024
    control = f'''Package: pairit
Version: {version.replace('-', '~', 1)}
Architecture: {architecture}
Maintainer: PairIt <kartikey060105@gmail.com>
Section: sound
Priority: optional
Installed-Size: {installed_kib}
Depends: {DEPENDENCIES}
Recommends: pipewire-pulse | pulseaudio
Homepage: https://pairit.kartikey.xyz
Description: Listen to computer audio through your phone
 PairIt sends computer audio to a paired phone over your local network.
 Includes its .NET runtime. Requires a graphical X11/XWayland session
 and a running PulseAudio or PipeWire PulseAudio-compatible user service.
'''
    # No maintainer scripts: installing never runs PairIt, edits user audio routes,
    # starts services, or touches pairing data in the user's home directory.
    result = b'!<arch>\n' + ar_member('debian-binary', b'2.0\n')
    result += ar_member('control.tar.gz', tar_bytes([('control', control.encode(), 0o644)]))
    result += ar_member('data.tar.gz', tar_bytes(files))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('publish', type=Path)
    parser.add_argument('--rid', choices=['linux-x64', 'linux-arm64'], required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    version = ET.parse(ROOT / 'linux/PairIt.Linux/PairIt.Linux.csproj').findtext('.//Version')
    architecture = 'amd64' if args.rid == 'linux-x64' else 'arm64'
    output = args.output or ROOT / 'artifacts/linux' / f'PairIt-{version}-{architecture}.deb'
    package(args.publish, architecture, version, output)
    print(f'Ubuntu/Debian installer: {output}')


if __name__ == '__main__':
    main()
