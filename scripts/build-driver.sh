#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${PAIRIT_DRIVER_OUTPUT_DIR:-$PWD/artifacts}"
driver="$output_dir/AudioRelayOutput.driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
xcrun clang -O2 -fblocks -std=c11 -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 \
  -bundle -framework CoreFoundation -framework CoreAudio \
  mac/driver/AudioRelayDriver.c -o "$driver/Contents/MacOS/AudioRelayOutput"
cp mac/driver/Info.plist "$driver/Contents/Info.plist"
cp mac/driver/APPLE-LICENSE.txt "$driver/Contents/Resources/APPLE-LICENSE.txt"
mkdir -p "$driver/Contents/Resources/en.lproj"
cp mac/driver/en.lproj/Localizable.strings "$driver/Contents/Resources/en.lproj/Localizable.strings"
codesign --force --sign - --identifier dev.bluetoothswitch.audio-output "$driver"
codesign --verify --strict "$driver"
root="$output_dir/driver-package/root"
mkdir -p "$root/Library/Audio/Plug-Ins/HAL"
ditto --norsrc --noextattr "$driver" "$root/Library/Audio/Plug-Ins/HAL/AudioRelayOutput.driver"
COPYFILE_DISABLE=1 \
pkgbuild --root "$root" --scripts mac/driver/installer \
  --component-plist mac/driver/components.plist \
  --identifier dev.bluetoothswitch.audio-output --version 0.2.0 \
  --install-location / "$output_dir/driver-package/component.pkg"
productbuild --package "$output_dir/driver-package/component.pkg" "$output_dir/Audio Relay Output.pkg"
echo "Built $driver and $output_dir/Audio Relay Output.pkg"
