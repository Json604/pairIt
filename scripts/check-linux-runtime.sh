#!/usr/bin/env bash
# Run on a Linux desktop/CI user session with pulseaudio and Xvfb installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${PAIRIT_DOTNET:-dotnet}"
export NUGET_PACKAGES="$ROOT/artifacts/linux/nuget"
mkdir -p "$ROOT/artifacts/linux"
# In an isolated PipeWire session the caller supplies the running audio server.
if ! pactl info >/dev/null 2>&1; then pulseaudio --start --exit-idle-time=-1; fi
previous_default=$(pactl get-default-sink)
sink=$(pactl load-module module-null-sink sink_name=pairit_test rate=48000 channels=2)
mic_sink=$(pactl load-module module-null-sink sink_name=pairit_mic_test rate=48000 channels=2)
player=''
cleanup() {
  if [ -n "$player" ]; then kill "$player" 2>/dev/null || true; fi
  if pactl list short sinks | awk '{print $2}' | grep -Fxq "$previous_default"; then
    pactl set-default-sink "$previous_default" || true
  fi
  pactl unload-module "$sink" || true
  pactl unload-module "$mic_sink" || true
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
"$DOTNET" run --project "$ROOT/linux/PairIt.Linux.Checks" --no-restore -c Release -- --audio --timing
"$DOTNET" run --project "$ROOT/linux/PairIt.Linux.Checks" --no-restore -c Release -- --routing
xvfb-run -a timeout 20 "$ROOT/artifacts/linux/${PAIRIT_LINUX_RID:-linux-x64}/PairIt" --smoke-test

"$DOTNET" restore "$ROOT/linux/PairIt.Linux.UiChecks/PairIt.Linux.UiChecks.csproj" --locked-mode
for theme in light dark; do
  args=()
  if [ "$theme" = dark ]; then args+=(--dark); fi
  xvfb-run -a -s '-screen 0 1280x800x24' "$DOTNET" run --project "$ROOT/linux/PairIt.Linux.UiChecks" --no-restore -c Release -- "$ROOT/artifacts/linux/ui-$theme" "${args[@]}"
done
AVALONIA_SCREEN_SCALE_FACTORS=2 xvfb-run -a -s '-screen 0 1280x800x24' "$DOTNET" run --project "$ROOT/linux/PairIt.Linux.UiChecks" --no-restore -c Release -- "$ROOT/artifacts/linux/ui-dark-2x" --dark
