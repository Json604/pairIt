"""Release gates must reject unsafe metadata and unverified executable tools."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FeedChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feed = load_script('check-update-feed')

    def document(self, **changes):
        entry = dict(platform='mac', bundleID='dev.bluetoothswitch.macrelay', build=11,
                     version='1.1.0', minimumOS='14.2',
                     url='https://github.com/Json604/pairIt/releases/tag/v1.1.0-preview.7')
        entry.update(changes)
        return json.dumps(dict(schema=1, releases=[entry])).encode()

    def test_accepts_versioned_release(self):
        self.assertEqual(len(self.feed.validate_feed(self.document())), 1)

    def test_rejects_mutable_or_ambiguous_links(self):
        for path in ('latest', 'tag/latest', 'tag/../other', 'tag/%2e%2e',
                     'tag/v1?redirect=elsewhere', 'tag/v1#fragment', 'tag/v1/extra'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.feed.validate_feed(self.document(url='https://github.com/Json604/pairIt/releases/' + path))

    def test_rejects_wrong_identity_and_noninteger_build(self):
        for values in ({'bundleID': 'other.app'}, {'build': True}, {'build': 0}, {'minimumOS': 'new'}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.feed.validate_feed(self.document(**values))

    def test_rejects_duplicate_or_oversized_feed(self):
        data = json.loads(self.document())
        data['releases'] *= 2
        for raw in (json.dumps(data).encode(), b' ' * 65537):
            with self.assertRaises(ValueError):
                self.feed.validate_feed(raw)

    def test_accepts_github_asset_redirect_but_not_unrelated_destination(self):
        original = 'https://github.com/Json604/pairIt/releases/download/v1.1.0/PairIt.zip'
        self.feed.validate_destination(original, 'https://release-assets.githubusercontent.com/asset?signature=example', 'mac')
        for destination in ('http://release-assets.githubusercontent.com/asset',
                            'https://example.com/PairIt.zip'):
            with self.assertRaises(ValueError):
                self.feed.validate_destination(original, destination, 'mac')


class ToolIntegrityChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = load_script('release_tools')

    def test_rejects_modified_cached_tool_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'tool.jar'
            path.write_bytes(b'untrusted')
            with patch('urllib.request.urlopen') as network, self.assertRaises(ValueError):
                self.tools.verified_download('https://example.invalid/tool.jar', path, '0' * 64)
            network.assert_not_called()
            self.assertEqual(path.read_bytes(), b'untrusted')

    def test_failed_download_never_creates_trusted_cache_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'tool.jar'
            with patch('urllib.request.urlopen') as network:
                response = network.return_value.__enter__.return_value
                response.read.side_effect = [b'tampered', b'']
                with self.assertRaises(ValueError):
                    self.tools.verified_download('https://example.invalid/tool.jar', path, '0' * 64)
            self.assertFalse(path.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
