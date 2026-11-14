#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${PAIRIT_MAC_OUTPUT:-$PWD/artifacts/PairIt.app}"
build_root="${PAIRIT_MAC_BUILD_DIR:-$PWD/artifacts/mac-build}"
mkdir -p "$build_root"
python3 scripts/prepare-sparkle.py
sparkle="$PWD/artifacts/tools/sparkle-2.10.1"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
PAIRIT_DRIVER_OUTPUT_DIR="$build_root" bash scripts/build-driver.sh
cp "$build_root/Audio Relay Output.pkg" "$app/Contents/Resources/Audio Relay Output.pkg"
rm -f "$app/Contents/Resources/relay-config.json" "$app/Contents/Resources/relay-identity.p12"
cp mac/Relay.swift "$build_root/main.swift"
for architecture in arm64 x86_64; do
  xcrun clang -O2 -std=c11 -target "$architecture-apple-macos14.2" -c mac/PacketRing.c -o "$build_root/PacketRing-$architecture.o"
  xcrun swiftc -O -swift-version 5 -target "$architecture-apple-macos14.2" -import-objc-header mac/PacketRing.h -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework CoreAudio -framework AudioToolbox -framework AVFAudio -framework Network -framework Security mac/LocalIdentity.swift apple/ComputerVolume.swift mac/RelayServer.swift mac/MicrophoneOutput.swift mac/WiFiServer.swift mac/SyncOutput.swift apple/RelayStyle.swift apple/ReleaseUpdates.swift mac/MacInstallerUpdates.swift mac/MacCompanion.swift mac/AppDelegate.swift "$build_root/main.swift" "$build_root/PacketRing-$architecture.o" -o "$build_root/AudioRelay-$architecture"
done
xcrun lipo -create "$build_root/AudioRelay-arm64" "$build_root/AudioRelay-x86_64" -output "$app/Contents/MacOS/AudioRelay"
cp design/fonts/ChakraPetch-*.ttf "$app/Contents/Resources/"
cp design/fonts/OFL.txt "$app/Contents/Resources/ChakraPetch-OFL.txt"
cp mac/Info.plist "$app/Contents/Info.plist"
cp mac/AudioRelay.icns "$app/Contents/Resources/AudioRelay.icns"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
codesign --force --sign - --identifier dev.bluetoothswitch.macrelay "$app"
echo "Built $app"
