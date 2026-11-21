#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${PAIRIT_DOTNET:-$ROOT/artifacts/toolchains/dotnet/dotnet}"
if [ ! -x "$DOTNET" ]; then DOTNET="$(command -v dotnet || true)"; fi
if [ -z "$DOTNET" ] || [ ! -x "$DOTNET" ]; then
  echo "Install .NET SDK 10.0.404 or set PAIRIT_DOTNET to its dotnet executable." >&2
  exit 1
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export NUGET_PACKAGES="$ROOT/artifacts/feature-preview/windows/nuget"
OUTPUT="${PAIRIT_WINDOWS_OUTPUT_DIR:-$ROOT/artifacts/feature-preview/windows/win-x64}"
cd "$ROOT/windows"
if [ "$("$DOTNET" --version)" != "10.0.404" ]; then
  echo "This preview requires the pinned .NET SDK 10.0.404." >&2
  exit 1
fi
LOCKED=--locked-mode
if [ "${1:-}" = "--update-lock" ]; then LOCKED=--force-evaluate; fi
"$DOTNET" restore PairIt.Windows/PairIt.Windows.csproj -p:RuntimeIdentifier=win-x64 -p:SelfContained=true "$LOCKED"
"$DOTNET" publish PairIt.Windows/PairIt.Windows.csproj --no-restore -c Release -r win-x64 --self-contained true \
  -o "$OUTPUT" -p:DebugType=None -p:DebugSymbols=false
if [ "${1:-}" != "--build-only" ]; then
  "$DOTNET" restore PairIt.ProtocolCheck/PairIt.ProtocolCheck.csproj "$LOCKED"
  "$DOTNET" run --project PairIt.ProtocolCheck/PairIt.ProtocolCheck.csproj --no-restore -c Release
fi
python3 "$ROOT/scripts/write-install-inventory.py" "$OUTPUT"
echo "Windows x64 preview: $OUTPUT/PairIt.exe"
echo "Cross-compilation and synthetic protocol checks do not verify Windows audio/UI runtime behavior."
