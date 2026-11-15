"""Check both developer script branches without Android SDK, real keys or builds."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AndroidBuildScriptChecks(unittest.TestCase):
    def test_default_and_preview_build_arguments(self):
        for preview in ('0', '1'):
            with self.subTest(preview=preview), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root/'scripts').mkdir()
                android = root/'android'
                apk = android/'build/outputs/apk/debug/AudioRelay-debug.apk'
                apk.parent.mkdir(parents=True)
                apk.write_bytes(b'fixture')
                (android/'build/debug.keystore').touch()
                script = root/'scripts/build-android.sh'
                script.write_text((ROOT/'scripts/build-android.sh').read_text())
                gradle = android/'gradlew'
                gradle.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > args.txt\n')
                gradle.chmod(0o755)
                env = dict(os.environ, PAIRIT_ANDROID_UI_PREVIEW=preview,
                           PAIRIT_ANDROID_OUTPUT=str(root/'result.apk'))
                subprocess.run(['/bin/bash', str(script)], env=env, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                args = (android/'args.txt').read_text().splitlines()
                self.assertEqual(args, ['assembleDebug', '--console=plain'] +
                                 (['-PpairitUiPreview=true'] if preview=='1' else []))
                self.assertEqual((root/'result.apk').read_bytes(), b'fixture')

if __name__ == '__main__':
    unittest.main()
