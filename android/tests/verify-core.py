#!/usr/bin/env python3
"""Run Android's platform-independent security checks using the installed JDK."""
from pathlib import Path
import subprocess
import tempfile

android = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="pairit-android-check-") as temporary:
    subprocess.run(["javac", "-d", temporary,
                    str(android / "src/dev/bluetoothswitch/relay/ReleaseDownloadLink.java"),
                    str(android / "tests/ReleaseDownloadLinkCheck.java")], check=True)
    subprocess.run(["java", "-cp", temporary,
                    "dev.bluetoothswitch.relay.ReleaseDownloadLinkCheck"], check=True)
