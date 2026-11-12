#!/usr/bin/env bash
# Run on a Linux desktop/CI user session with pulseaudio and Xvfb installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${PAIRIT_DOTNET:-dotnet}"
export NUGET_PACKAGES="$ROOT/artifacts/linux/nuget"
pulseaudio --start --exit-idle-time=-1
sink=$(pactl load-module module-null-sink sink_name=pairit_test rate=48000 channels=2)
player=''
cleanup() {
  if [ -n "$player" ]; then kill "$player" 2>/dev/null || true; fi
  pactl unload-module "$sink" || true
}
trap cleanup EXIT
pactl set-default-sink pairit_test
python3 - "$ROOT/artifacts/linux/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], 'wb') as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(48000)
    f.writeframes(b''.join(struct.pack('<hh', *([int(8000 * math.sin(i * math.tau * 440 / 48000))] * 2)) for i in range(48000 * 30)))
PY
paplay --device=pairit_test "$ROOT/artifacts/linux/tone.wav" &
player=$!
"$DOTNET" run --project "$ROOT/linux/PairIt.Linux.Checks" --no-restore -c Release -- --audio
xvfb-run -a timeout 20 "$ROOT/artifacts/linux/linux-x64/PairIt" --smoke-test
