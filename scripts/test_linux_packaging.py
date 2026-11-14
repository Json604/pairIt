"""Package metadata and payload must install without privileged custom scripts."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_linux_deb', Path(__file__).with_name('package-linux-deb.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class LinuxPackageTests(unittest.TestCase):
    def test_deb_contains_dependencies_launcher_and_preserves_user_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / 'publish'; folder.mkdir()
            (folder / 'PairIt').write_bytes(b'fake-executable')
            (folder / 'PairIt.dll').write_bytes(b'fake-assembly')
            (folder / 'PairIt.deps.json').write_text(json.dumps({'libraries': {'PairIt/1.1.0-preview.17': {}}, 'runtimeTarget': {'name': '.NETCoreApp,Version=v10.0/linux-x64'}}))
            output = Path(tmp) / 'app.deb'
            packager.package(folder, 'amd64', '1.1.0-preview.17', output)
            data = output.read_bytes(); self.assertEqual(data[:8], b'!<arch>\n')
            members = {}; offset = 8
            while offset < len(data):
                header = data[offset:offset + 60]; length = int(header[48:58])
                members[header[:16].decode().strip().rstrip('/')] = data[offset + 60:offset + 60 + length]
                offset += 60 + length + length % 2
            self.assertEqual(members['debian-binary'], b'2.0\n')
            with tarfile.open(fileobj=io.BytesIO(members['control.tar.gz'])) as archive:
                self.assertEqual(archive.getnames(), ['./control'])
                control = archive.extractfile('./control').read().decode()
                self.assertIn('Version: 1.1.0~preview.17', control)
                self.assertIn('pulseaudio-utils', control)
                self.assertIn('Architecture: amd64', control)
            with tarfile.open(fileobj=io.BytesIO(members['data.tar.gz'])) as archive:
                self.assertTrue(archive.getmember('./opt/pairit').isdir())
                self.assertEqual(archive.getmember('./opt/pairit').mode, 0o755)
                self.assertEqual(archive.getmember('./opt/pairit/PairIt').mode, 0o755)
                self.assertIn('./usr/share/applications/pairit.desktop', archive.getnames())
                self.assertFalse(any('/home/' in name or 'identity.json' in name for name in archive.getnames()))

    def test_rejects_incomplete_payload_and_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                packager.package(Path(tmp), 'amd64', '1.1.0', Path(tmp) / 'app.deb')
            with self.assertRaises(ValueError):
                packager.package(Path(tmp), 'armhf', '1.1.0', Path(tmp) / 'app.deb')
