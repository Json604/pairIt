#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p android/build artifacts
if [ ! -f android/build/debug.keystore ]; then
  keytool -genkeypair -keystore android/build/debug.keystore -storepass android -keypass android -alias androiddebugkey -dname 'CN=Audio Relay Local Debug' -keyalg RSA -validity 10000 >/dev/null 2>&1
fi
# macOS ships Bash 3.2, where expanding an empty array under nounset fails.
if [ "${PAIRIT_ANDROID_UI_PREVIEW:-0}" = "1" ]; then
  (cd android && ./gradlew assembleDebug --console=plain -PpairitUiPreview=true)
else
  (cd android && ./gradlew assembleDebug --console=plain)
fi
output="${PAIRIT_ANDROID_OUTPUT:-artifacts/audio-relay-debug.apk}"
mkdir -p "$(dirname "$output")"
cp android/build/outputs/apk/debug/AudioRelay-debug.apk "$output"
echo "Built $output"
