#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${1:-simulator}"
case "$variant" in
  simulator)
    destination='generic/platform=iOS Simulator'; configuration=Debug; product=Debug-iphonesimulator; suffix=Simulator
    # Xcode embeds simulated entitlements for Keychain access when signing is enabled.
    # Let Xcode manage these; manually signing restricted entitlements prevents launch.
    signing_options=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
    ;;
  device)
    destination='generic/platform=iOS'; configuration=Release; product=Release-iphoneos; suffix=Unsigned
    signing_options=(CODE_SIGNING_ALLOWED=NO)
    ;;
  *) echo 'Usage: scripts/build-ios.sh [simulator|device]' >&2; exit 2 ;;
esac
output_dir="${PAIRIT_IOS_OUTPUT_DIR:-artifacts}"
mkdir -p "$output_dir"
xcodebuild -project ios/AudioRelay.xcodeproj -scheme AudioRelay -configuration "$configuration" -destination "$destination" -derivedDataPath "$output_dir/ios-build" "${signing_options[@]}" build > "$output_dir/ios-$variant-build.log" 2>&1 || { tail -80 "$output_dir/ios-$variant-build.log"; exit 1; }
ditto "$output_dir/ios-build/Build/Products/$product/Audio Relay.app" "$output_dir/Audio Relay iOS $suffix.app"
echo "Built $output_dir/Audio Relay iOS $suffix.app"
