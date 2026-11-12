#!/bin/bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo after quitting Audio Relay and choosing your normal Mac output." >&2
  exit 1
fi
driver="/Library/Audio/Plug-Ins/HAL/AudioRelayOutput.driver"
if [[ -d "$driver" ]]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")
  [[ "$identifier" == dev.bluetoothswitch.audio-output ]] || { echo "Unexpected bundle; leaving it untouched." >&2; exit 1; }
  rm -rf -- "$driver"
fi
/usr/sbin/pkgutil --forget dev.bluetoothswitch.audio-output >/dev/null 2>&1 || true
/usr/bin/killall coreaudiod 2>/dev/null || true
echo "Audio Relay output removed."
