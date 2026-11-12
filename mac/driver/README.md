# Audio Relay output

This HAL AudioServerPlugIn publishes an output device with the downstream
presentation latency in `kAudioDevicePropertyLatency`. The former aggregate's
extra-output-latency key changed its safety offset, while a live AUHAL client
still observed only about 24 ms, even with a 619 ms correction selected.

`AudioRelayDriver.c` is adapted from Apple's 2024 [Creating an Audio Server
Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
sample. Its license is in `APPLE-LICENSE.txt`. The sample's object/property
implementation is retained, with unique bundle/device identifiers, a 48 kHz
initial rate and a 512-frame timestamp period. `RelayProperties.h` publishes
only the output stream, removes the sample's nonfunctional controls and input,
and implements `arly`, a CFNumber of downstream milliseconds (0–2000).

The Mac app sets `arly`; media clients read the standard device latency. There
is no artificial PCM delay in the driver. Audio capture remains in the Mac app's
process tap, with the existing macOS recording permission. The driver contains
no networking, audio recording, or headphone-specific timing constants.

Build: `bash scripts/build-driver.sh`. This creates a universal Apple Silicon /
Intel driver and `artifacts/Audio Relay Output.pkg`. Installing requires a Mac
administrator and briefly restarts system audio. It installs only
`/Library/Audio/Plug-Ins/HAL/AudioRelayOutput.driver`; existing drivers are untouched.

To remove, quit Audio Relay and choose your normal output in Sound settings,
then run `sudo bash scripts/uninstall-driver.sh`. This also briefly restarts
system audio. Rebooting will also reload HAL plug-ins.

Current packages are ad hoc signed development builds, not a notarized public
release. Build success alone does not establish that macOS loads the driver or
that a video player honors its timing; use `scripts/inspect-output-timing.swift`
and the real-device listening checklist before claiming synchronization.
