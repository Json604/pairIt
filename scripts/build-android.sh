#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p android/build artifacts
if [ ! -f android/build/debug.keystore ]; then
  keytool -genkeypair -keystore android/build/debug.keystore -storepass android -keypass android -alias androiddebugkey -dname 'CN=Audio Relay Local Debug' -keyalg RSA -validity 10000 >/dev/null 2>&1
fi
preview_options=()
if [ "${PAIRIT_ANDROID_UI_PREVIEW:-0}" = "1" ]; then preview_options=(-PpairitUiPreview=true); fi
(cd android && ./gradlew assembleDebug --console=plain "${preview_options[@]}")
output="${PAIRIT_ANDROID_OUTPUT:-artifacts/audio-relay-debug.apk}"
mkdir -p "$(dirname "$output")"
cp android/build/outputs/apk/debug/AudioRelay-debug.apk "$output"
echo "Built $output"
