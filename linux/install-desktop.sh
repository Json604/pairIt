#!/usr/bin/env bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")" && pwd)"
case "$app_dir" in *$'\n'*|*'%'*|*'"'*|*'`'*|*'$'*|*'\'*) echo 'Move PairIt to a folder without special characters before installing its launcher.' >&2; exit 1;; esac
launcher_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$launcher_dir"
cat > "$launcher_dir/pairit.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=PairIt
Comment=Computer audio through your phone
Exec="$app_dir/PairIt"
Icon=$app_dir/PairIt.ico
Terminal=false
Categories=AudioVideo;Audio;
DESKTOP
chmod 644 "$launcher_dir/pairit.desktop"
echo 'PairIt added to your application menu. Keep this extracted folder in place.'
