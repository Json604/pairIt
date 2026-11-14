#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${PAIRIT_DMG_APP:-$PWD/artifacts/PairIt.app}"
output="${PAIRIT_DMG_OUTPUT:-$PWD/artifacts/PairIt-Mac-1.1.0.dmg}"
[[ -d "$app" ]] || { echo 'Build PairIt.app first.' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/pairit-dmg.XXXXXX")
volume="PairIt Installer"
mounted=""
cleanup(){ if [[ -n "$mounted" ]]; then hdiutil detach "$mounted" -quiet || true; fi; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/PairIt.app"
ln -s /Applications "$work/stage/Applications"
python3 scripts/dmg-background.py "$work/stage/.background/install.png"
hdiutil create -quiet -volname "$volume" -srcfolder "$work/stage" -format UDRW "$work/install.dmg"
mounted="$work/mount"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$mounted" "$work/install.dmg"
osascript - "$mounted" <<'APPLESCRIPT'
on run argv
 tell application "Finder"
  set installFolder to (POSIX file (item 1 of argv)) as alias
  tell folder installFolder
   open
   set current view of container window to icon view
   set toolbar visible of container window to false
   set statusbar visible of container window to false
   set bounds of container window to {140, 140, 800, 588}
   set opts to icon view options of container window
   set arrangement of opts to not arranged
   set icon size of opts to 96
   set text size of opts to 15
   set background picture of opts to file ".background:install.png"
   set position of item "PairIt.app" to {170, 210}
   set position of item "Applications" to {490, 210}
   update without registering applications
   delay 2
   close
  end tell
 end tell
end run
APPLESCRIPT
sync
hdiutil detach -quiet "$mounted"; mounted=""
mkdir -p "$(dirname "$output")"
hdiutil convert -quiet "$work/install.dmg" -format UDZO -imagekey zlib-level=9 -o "$work/final.dmg"
mv "$work/final.dmg" "$output"
echo "Built $output"
