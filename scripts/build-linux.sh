#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${PAIRIT_DOTNET:-$ROOT/artifacts/toolchains/dotnet/dotnet}"
if [ ! -x "$DOTNET" ]; then DOTNET="$(command -v dotnet || true)"; fi
if [ -z "$DOTNET" ]; then echo 'Install .NET SDK 10.0.404 or set PAIRIT_DOTNET.' >&2; exit 1; fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export NUGET_PACKAGES="$ROOT/artifacts/linux/nuget"
cd "$ROOT/linux"
RID="${PAIRIT_LINUX_RID:-linux-x64}"
case "$RID" in linux-x64|linux-arm64) ;; *) echo 'Unsupported Linux architecture' >&2; exit 1;; esac
OUTPUT="$ROOT/artifacts/linux/$RID"
LOCKED=--locked-mode
if [ "${1:-}" = --update-lock ]; then LOCKED=--force-evaluate; fi
"$DOTNET" restore PairIt.Linux/PairIt.Linux.csproj -p:RuntimeIdentifier="$RID" -p:SelfContained=true "$LOCKED"
"$DOTNET" publish PairIt.Linux/PairIt.Linux.csproj --no-restore -c Release -r "$RID" --self-contained true -o "$OUTPUT" -p:DebugType=None -p:DebugSymbols=false
"$DOTNET" restore PairIt.Linux.Checks/PairIt.Linux.Checks.csproj "$LOCKED"
"$DOTNET" run --project PairIt.Linux.Checks/PairIt.Linux.Checks.csproj --no-restore -c Release
"$DOTNET" restore PairIt.UpdateChecks/PairIt.UpdateChecks.csproj "$LOCKED"
"$DOTNET" run --project PairIt.UpdateChecks/PairIt.UpdateChecks.csproj --no-restore -c Release
cp "$ROOT/linux/install-desktop.sh" "$OUTPUT/"
cp "$ROOT/windows/PairIt.Windows/PairIt.ico" "$OUTPUT/PairIt.ico"
mkdir -p "$OUTPUT/licenses"
cp "$ROOT/windows/licenses/dotnet-10.0.15-LICENSE.txt" "$OUTPUT/licenses/"
# Preserve package license notices shipped by the GUI dependencies.
python3 "$ROOT/scripts/package-linux-licenses.py" "$NUGET_PACKAGES" "$OUTPUT/licenses"
chmod +x "$OUTPUT/PairIt" "$OUTPUT/install-desktop.sh"
python3 "$ROOT/scripts/write-install-inventory.py" "$OUTPUT"
python3 "$ROOT/scripts/package-update-zip.py" "$OUTPUT" "$ROOT/artifacts/linux/PairIt-1.1.0-preview.28-$RID.zip"
COPYFILE_DISABLE=1 tar -czf "$ROOT/artifacts/linux/PairIt-1.1.0-preview.28-$RID.tar.gz" -C "$OUTPUT" .
python3 "$ROOT/scripts/package-linux-deb.py" "$OUTPUT" --rid "$RID"
echo "Linux preview: $OUTPUT/PairIt"
