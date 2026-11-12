#!/usr/bin/env python3
"""Regression: an external launch must not start a previously paired relay.

Run with a disposable API 29+ emulator whose AVD name starts with PairItAudit:
  python3 android/tests/verify-exported-launch.py --serial emulator-5580 \
      --apk android/build/outputs/apk/debug/AudioRelay-debug.apk

Build the APK with -PpairitUiPreview=true. This test replaces only that Preview
app's settings on the explicitly selected audit emulator, using synthetic data.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time
import re
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--serial", required=True)
parser.add_argument("--apk", type=Path, required=True)
args = parser.parse_args()
sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
adb = shutil.which("adb") or str(sdk / "platform-tools/adb")

def run(*command, input=None):
    return subprocess.run([adb, "-s", args.serial, *command], input=input,
                          text=True, check=True, capture_output=True, timeout=45).stdout

if not args.serial.startswith("emulator-"):
    parser.error("Use a disposable emulator, never a physical device")
if not run("emu", "avd", "name").splitlines()[0].startswith("PairItAudit"):
    parser.error("The disposable AVD name must start with PairItAudit")
deadline = time.monotonic() + 60
while run("shell", "getprop", "sys.boot_completed").strip() != "1":
    if time.monotonic() >= deadline:
        raise TimeoutError("Audit emulator did not finish booting")
    time.sleep(1)

package = "dev.bluetoothswitch.relay.preview"
run("install", "-r", str(args.apk.resolve()))
run("shell", "am", "force-stop", package)
run("shell", "run-as", package, "mkdir", "-p", "shared_prefs")
preferences = f'''<?xml version="1.0" encoding="utf-8"?>
<map>
  <string name="host">127.0.0.1</string>
  <string name="pin">{'a' * 64}</string>
  <string name="token">{'b' * 64}</string>
  <string name="computer_name">Synthetic audit computer</string>
  <string name="output">SPEAKER</string>
  <boolean name="asked_controls_notifications" value="true" />
</map>
'''
run("shell", f"run-as {package} sh -c 'cat > shared_prefs/relay.xml'", input=preferences)
run("logcat", "-c")
try:
    run("shell", "am", "start", "-W", "-n", package + "/dev.bluetoothswitch.relay.MainActivity",
        "--ez", "listen_from_tile", "true")
    # Allow posted UI callbacks and asynchronous service startup to run.
    time.sleep(3)
    logs = run("logcat", "-d", "-s", "AudioRelayLab:I", "AndroidRuntime:E", "*:S")
    settings = run("shell", "run-as", package, "cat", "shared_prefs/relay.xml")
    assert "FATAL EXCEPTION" not in logs, "External launch crashed the app"
    assert "STATE CONNECTING" not in logs, "Forged tile extra started the audio service"
    assert 'name="controls_source"' not in settings, "External launch changed the selected audio source"
    print("PASS: forged external shortcut opens the UI without starting relay audio")
    run("shell", "uiautomator", "dump", "/sdcard/pairit-audit-window.xml")
    window = ET.fromstring(run("shell", "cat", "/sdcard/pairit-audit-window.xml"))
    computer = next(node for node in window.iter("node")
                    if node.get("text") == "Computer" and node.get("clickable") == "true")
    left, top, right, bottom = map(int, re.findall(r"\d+", computer.get("bounds")))
    run("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))
    time.sleep(1)
    logs = run("logcat", "-d", "-s", "AudioRelayLab:I", "AndroidRuntime:E", "*:S")
    assert "FATAL EXCEPTION" not in logs, "Explicit playback crashed the app"
    assert "STATE CONNECTING" in logs, "The explicit Computer control did not start playback"
    print("PASS: explicit Computer control still starts a paired relay")
finally:
    run("shell", "am", "force-stop", package)
