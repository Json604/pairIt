# Working on PairIt

This guide applies to the whole repository. Start here, then read the relevant code
and tests before changing behaviour. Keep it useful to a fresh clone: no personal
handoffs, machine-specific paths, credentials or deployment/account records.

## Start here

1. Read [README.md](README.md) for product behaviour, platform requirements and limitations,
   and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution expectations.
2. Check `git status --short`. Preserve unrelated work; do not reset the working tree.
3. Locate the affected platform below. For cross-platform changes, inspect both ends of
   the protocol and all clients using shared code. Reproduce bugs with an isolated test
   where practical, then make the smallest coherent change.
4. Run relevant checks, inspect `git diff --check`, and report what changed, what passed,
   and what remains untested. Build success is not physical-device acceptance.

## Product and compatibility rules

- PairIt streams computer audio to phone speakers or connected headphones over the local
  network. It is free with ads, including up to four phones in Listen Together. There is
  no payment tier. Preserve ad consent and do not insert ads into active playback.
- Preserve TLS certificate pinning, token authentication and comparison-code approval.
  Discovery is not authentication; pairing QR codes contain credentials and are private.
- Respect explicit Pause, Disconnect and Stop sharing. Temporary capture/network failures
  must not permanently disable future retries or silently switch to a different source.
- Keep saved computer pairings independent. Forgetting one must not erase the others,
  consent preferences or installation identity. Preserve migration from older storage.
- Phone speakers are valid outputs. A Together host needs a connected computer; guests
  can receive invitations while PairIt is foregrounded on any tab. Keep host/guest state,
  capacity limits and independent listener controls consistent across platforms.
- Preserve the app’s established black/blue palette, dotted discovery background, type
  and native controls. Reuse existing loading indicators and reduced-motion behaviour.

## Source map

| Area | Start with |
| --- | --- |
| Android | `android/src/dev/bluetoothswitch/relay/` — `MainActivity`, `RelayService`, `RelayConnection`, `RelaySettings` |
| iPhone | `ios/AudioRelay/` — `ReceiverView`, `RelayReceiver`, `RelayTransport`, `PairingStore` |
| Shared Apple code | `apple/` |
| Mac companion/audio driver | `mac/` — `RelayServer.swift`, `WiFiServer.swift`, `SyncOutput.swift`, `driver/` |
| Shared Windows/Linux logic | `windows/PairIt.Core/` — `DesktopSessions`, `RelayServer`, updater and protocol code |
| Windows UI/audio | `windows/PairIt.Windows/` |
| Linux UI/audio/routing | `linux/PairIt.Linux/`, `linux/PairIt.Linux.Core/` |
| Optional public-report server | `reports/`; read its README before touching request/quota/privacy behaviour |
| Builds and CI | `scripts/`, `.github/workflows/ci.yml` |

## Build and validation

Use Python 3.12+, Java 21 with Android SDK/build-tools36, full Xcode for Apple, and
.NET SDK **10.0.404** for Windows/Linux (see their `global.json` files). Set
`ANDROID_HOME` or `android/local.properties`; `PAIRIT_DOTNET` can point to your SDK.
Run commands from the repository root unless noted. Build only affected platforms;
do not run concurrent .NET builds that share the same `obj` directory.

```sh
# Fast repository checks
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check-update-feed.py --offline
git diff --check

# Android: separate Preview package with test ads
python3 android/tests/verify-core.py
python3 android/tests/verify-pairing-archive.py
PAIRIT_ANDROID_UI_PREVIEW=1 bash scripts/build-android.sh
(cd android && ./gradlew lintDebug -PpairitUiPreview=true)

# Apple (macOS/Xcode): compile; these build commands do not launch audio
bash scripts/build-mac.sh
bash scripts/build-ios.sh simulator
python3 scripts/verify-receiver-handoff.py

# Desktop (these scripts also run platform/protocol checks)
bash scripts/build-windows.sh
bash scripts/build-linux.sh
# ARM64 packaging, when affected:
PAIRIT_LINUX_RID=linux-arm64 bash scripts/build-linux.sh

# Reporting server: isolated tests, not production requests
python3 -m unittest discover -s reports -p 'test_*.py'
```

Windows also supports `powershell -File scripts/build-windows.ps1`. Outputs go to
ignored `artifacts/`. See CI for additional protocol, identity, invitation and Linux
routing checks. Physical calls, Bluetooth routing, latency, background recovery and
UI usability need real-device tests; do not infer those results from synthetic checks.
Do not launch audio receivers, restart system audio, install drivers or replace an
existing app/pairing on a contributor’s machine without their authorization.

## Generated files and releases

- Edit `scripts/generate-ios-project.py` for generated Xcode project configuration, then
  run it. Edit `scripts/prepare-play-content.py` for generated Android help/privacy text,
  then run it. Inspect generated diffs; do not hand-edit only the generated copy.
- Read build numbers from `release/apple/release.json`, `release/google-play/release.json`,
  `mac/Info.plist` and the Windows/Linux app `.csproj` files. Do not bump them for ordinary
  contribution work or assume a source change has shipped.
- Source/contributions live in `Json604/pairIt`. Existing binaries, signed update feeds
  and in-app reports live in `Json604/pairIt-download`. Preserve those endpoints and
  updater trust keys; do not migrate them as a routine cleanup.
- Publication is separate from implementation. Follow [RELEASING.md](RELEASING.md) when
  explicitly asked to release. Publish verified assets before feeds and website links.
  A source push does not deploy the separate website or roll out store builds.
- Forks need their own app IDs, signing identities, ads, report service and update feeds.
  Never use production ads or reporting endpoints for automated development tests.

## Safety and current follow-ups

Keep secrets, pairing data, local logs and signing material out of commits and tool
output. Use [SECURITY.md](SECURITY.md) for private vulnerability reporting. Preserve
[third-party notices](THIRD_PARTY_NOTICES.md); original MIT licensing does not replace
SDK/font/driver terms. Do not rewrite history, alter visibility or publish builds unless
requested. Update this guide when workflows change, rather than adding a chronological
personal work log.

As of 2026-11-15, physical Windows and iPhone acceptance remains outstanding. Recent
reconnect/multiple-pairing fixes and test limitations are recorded in
[the verification notes](docs/reconnect28-mobile35.md). Other follow-ups include Gradle
dependency locking/checksum verification and safer fork/development service configuration.
Consult current issues and release notes before treating dated findings as still open.
