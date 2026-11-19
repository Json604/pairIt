# PairIt - AudioRelay

Listen to your computer through your phone’s headphones, wired output or speaker.
PairIt sends audio from Mac, Windows or Linux to Android or iPhone over an encrypted
local connection. Up to four phones can listen, with separate volume controls.
No PairIt account or cloud audio server is required.

[Website](https://pairit.kartikey.xyz) · [Downloads](https://pairit.kartikey.xyz/downloads.html) · [Releases](https://github.com/Json604/pairIt-download/releases)

## Platforms

| Platform | Requirements | Availability |
| --- | --- | --- |
| Mac | macOS 14.2+, Apple Silicon or Intel | Signed, notarized published downloads |
| Android | Android 10+ | APK downloads and invited Google Play testing |
| iPhone | iOS 17+ | Development/testing; see downloads for public availability |
| Windows | Windows 10 build 19041+, x64 | Unsigned preview |
| Linux | Ubuntu 24.04 / Debian 12 or newer, x64 or ARM64; X11/XWayland, PipeWire/PulseAudio | Preview |

Published downloads can lag behind this source tree. A Git push does not update
installed apps. Windows, Linux and iPhone still require physical-device playback
validation; a successful build is not evidence of identical behavior on every OS.

## Connect

1. Install the computer companion and phone app. Put both on a reachable local network.
2. Choose the phone speaker or connect headphones to the phone. Start sharing on the computer.
3. Scan the computer’s QR code in PairIt, or paste its pairing link. A valid scanned
   code verifies the computer and connects. Android and iPhone can also request
   pairing from a nearby Mac: compare the code on both screens and approve on the Mac.
   Windows and Linux use QR/link pairing for a new phone.
4. Start audio. Choose **This phone** or **Computer** to change the shared destination.
   Choose a local phone output from the output picker. **Refresh audio** clears the
   playback buffer if timing drifts.

**Connect** lists computers advertising PairIt, not all Wi-Fi devices.
**Together** lists nearby phones with PairIt open in the foreground, including phones
on Connect or Settings. Simply installing PairIt does not make a device visible.
Wired computers on the same LAN can appear too. Connect the host phone to a computer,
then open Together and tap a nearby phone to invite it. Compare the displayed code
and accept on both phones. The guest verifies the computer before connecting; it
does not need to scan the computer’s pairing code separately. Speakers and headphones
are valid outputs. A guest can leave the group before joining another.
**Share app** is separate, for someone without PairIt. Invitations expire after
65 seconds; keep PairIt in the foreground throughout the exchange.

Invitations use fresh P-256 ECDH keys and AES-256-GCM encryption; no pairing token
is advertised through Bonjour. Comparing the code on both phones authenticates
the exchange. Do not accept mismatching codes or unexpected invitations. Each
accepted phone receives access to the same computer; the existing four-listener
limit still applies.

Switching to Computer keeps live control connections and saved pairings; paused
phones stay paused. The destination applies to all listeners. **Disconnect** ends
one phone’s live session; **Stop sharing** ends the computer’s live sessions.
**Forget this computer** removes only that computer’s saved credentials. Settings
lists all saved computers. Older builds retained only one pairing; computers already
overwritten by those builds must be paired once again.

Android has notification controls and a Quick Settings tile. iPhone has system
media controls and Home/Lock Screen shortcuts. After calls or another phone app
interrupts playback, resume through PairIt or its available system controls.
Headphone play/pause controls this phone’s relay. On a Mac where PairIt’s headphone
controls are allowed, pausing the last listening phone also pauses the Mac’s video or
music, and resuming plays it again (other computers may keep playing).

## Computer setup and limits

- **Mac:** complete the included audio-output setup and allow system audio capture.
  The Mac lists each connected phone with its own pause/resume, disconnect and (for
  updated phones) volume slider. With an updated phone, the Mac volume keys change that
  phone’s own media volume instead of attenuating its audio; with one phone the Mac
  volume follows the phone. **Headphone buttons** (Accessibility permission, used only
  to send the system Play/Pause key) lets a phone pause and resume Mac media; if the
  key does not silence the Mac, PairIt presses it again to undo. Earphone next/previous
  skip tracks on the Mac. When the Mac player is paused, updated phones show "Paused on
  computer" and any earphone press starts it again; play/next on the Mac resumes a phone
  the listener paused (after a real stop, not a gap between songs).
  **Paired phones** lists phones that connected before; **Connect** works while PairIt
  is open on that phone. The phone verifies the request with the Mac over the pinned
  connection before connecting. Phones advertise only daily-rotating tags that only
  their paired computer can recognise.
  A connected, paused phone holds the relay output. When the last phone disconnects
  or times out, the Mac restores its previous output. The driver reports latency
  to compatible video players; it cannot remove Bluetooth latency for live audio.
- **Windows:** extract the entire ZIP and run `PairIt.exe`. Select the output your
  apps use. Local speakers keep playing unless you use a separately installed
  virtual render device. Supported players can respond to a best-effort pause;
  PairIt does not automatically press Play.
- **Linux:** on Ubuntu/Debian, open the matching `.deb` with your graphical package
  installer, choose **Install**, then open PairIt from the application menu. Required
  libraries and audio client tools are declared as package dependencies. Other
  compatible glibc distributions can use the portable archive; see `linux/START-HERE.txt`
  for dependencies. Use **Pair a phone** to select an output and start sharing.
  Phone playback temporarily routes the selected output into a private sink, avoiding
  duplicate laptop-speaker audio. Computer or final disconnect restores playback;
  pausing an already connected phone holds the silent route. Unrelated outputs and
  manual routing choices are preserved. Closing the window stops sharing. Linux
  has no automatic player pause or video compensation.
- **Low latency:** optional, off by default in phone Settings. Phones learn the network’s
  jitter instead of holding a fixed 320 ms cushion (60 ms minimum for Mac and Bluetooth),
  so game and click sounds arrive sooner, but busy Wi-Fi can cause audio drops. Windows/
  Linux local outputs keep their existing learned buffer. Bluetooth’s own delay applies.
- **Timing:** updated companions and phones negotiate one presentation time for
  multiple active listeners, compensating for each phone’s measured output delay.
  Allow a few seconds for “Learning shared timing” to finish. Older phones retain
  their existing behavior; update every listener for shared timing. OS timestamps
  are estimates, so acoustic synchronization still needs physical verification.
  Solo listening retains its existing buffer. Linux/Windows do not provide the
  Mac driver’s system video compensation. Two headphones on one phone depend on
  that phone’s own audio-sharing support.
- **Reconnect:** Android’s running media service retries after network loss; swiping
  away its screen differs from force-stopping the app. iOS retries while execution
  is available, but force-quitting prevents background reconnection. Explicit pause,
  disconnect and disabled auto-reconnect are respected. Desktop companions must stay running.
- **Network:** guest isolation, firewalls, VPNs and local-network permissions can
  block discovery or audio. PairIt uses TCP 5002 and local multicast UDP 5353.
  Do not port-forward it. Clear manual address overrides when changing networks.
  Supported tethering/hotspot links can work; a USB cable alone is insufficient.

The Mac audio-output installer requires administrator approval and briefly restarts
system audio. Keep an existing working driver unless an update requires replacement.
To uninstall the driver, quit PairIt, select your normal output and run
`sudo bash scripts/uninstall-driver.sh`; this also restarts system audio.

## Security and privacy

Audio travels over TLS 1.2 or newer. Phones verify the paired computer’s SHA-256
certificate fingerprint before sending its random pairing token. Discovery publishes
names, platforms and public fingerprints, never the private token. Discovery alone
is not proof of identity; compare the displayed code for first-time nearby approval.

QR links contain credentials encoded as base64, not encrypted QR content. Keep them
private. Anyone holding a valid copied code can pair while sharing is enabled.
There is no per-phone revocation: forgetting a computer on one phone does not revoke
other copies. Stop sharing if a code leaks. Do not delete identity files as routine
troubleshooting; that invalidates existing pairings.

PairIt does not record audio. Phone apps show a banner ad and an occasional ad while the
app opens (at most every 3 minutes, never while that phone plays audio, never on connect);
ad/consent requests,
Android scanner telemetry and update checks are separate from local audio.
Optional **Report a problem** on Android/iOS sends the text you submit to a dedicated
HTTPS service, which publishes it as a public issue in `Json604/pairIt-download`.
The form discloses this before submission. App/OS version details are optional;
no audio, pairing credentials, device names, network addresses or raw logs are
attached. The service uses keyed hashes of the request IP and a random app-installation
identifier for rate limits, and stores retry metadata rather than report text.
Each installation can submit five new reports per rolling 24 hours; the form shows
the remaining wait when that limit is reached. This is not a hardware identifier. GitHub stores the public issue. The app
keeps the draft locally until confirmed. See `reports/README.md` for operations.

See the [privacy policy](https://pairit.kartikey.xyz/privacy.html).
Encryption does not protect compromised endpoints or prevent every local-network
attack. Automated checks and source review are not a guarantee of zero vulnerabilities.

For private vulnerability reporting, see [SECURITY.md](SECURITY.md). Do not post
pairing codes, keys or private captures in public issues.

## External headphone recovery

With Auto-reconnect enabled, losing the active Bluetooth, wired or USB output
stops phone playback and releases its computer connection. The phone waits for
an external output, then reconnects to its saved computer and resumes after the
route is ready. Replacement headphones work on their first attachment. Manual
Pause, Disconnect, computer-output selection and explicit output choices cancel
pending recovery; the phone speaker never triggers it. Other listeners remain
connected. Both phones persist pending recovery against the saved computer identity,
with no elapsed-time expiry. Android restores its connected-device service after
system process eviction, and system Bluetooth connection broadcasts can wake it
when headphones return. An actual external audio route must be ready before it
starts audio; a Bluetooth keyboard connection alone cannot start playback.
Reopening the Android app also restores pending monitoring if the OS denied a restart.
Force-stop and manufacturer background restrictions can still prevent automatic wake-up.
iOS restores pending recovery when launched and checks route changes while it has
execution time. Ordinary audio-headset attachment cannot guarantee relaunch after
system suspension/termination or force-quit. No silent audio or perpetual wake lock
is used to keep either app alive. Desktop protocol and packages are unchanged.

## Build and check

Use Python 3.12+, full Xcode on macOS for Apple builds, Java 21 and Android SDK/build-tools 36
for Android, and .NET SDK **10.0.404** for Windows/Linux. Configure `ANDROID_HOME`
or `android/local.properties` with `sdk.dir` for Android.

```sh
git clone https://github.com/Json604/pairIt.git
cd pairIt
PAIRIT_ANDROID_UI_PREVIEW=1 bash scripts/build-android.sh
bash scripts/build-mac.sh
bash scripts/build-ios.sh simulator
bash scripts/build-windows.sh
bash scripts/build-linux.sh
PAIRIT_LINUX_RID=linux-arm64 bash scripts/build-linux.sh
```

On Windows, use `powershell -File scripts/build-windows.ps1`. iOS simulator builds
use `bash scripts/build-ios.sh simulator`. Outputs are in ignored `artifacts/`.
The simulator/Debug build uses test ads; you do not need to run a simulator for a
compile check. `bash scripts/build-ios.sh device` is an unsigned Release validation
build with the official ad configuration, not the contributor test-ad path. Never
click production ads during development. Distribution requires your signing environment;
Android release builds require the existing private upload key. The separate
Android Preview package uses test ads and can coexist with the Play installation.

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check-update-feed.py --offline
python3 android/tests/verify-core.py
# On macOS:
python3 scripts/verify-feature-server.py
python3 scripts/verify-feature-gateway.py
python3 scripts/verify-receiver-handoff.py
# From android/:
./gradlew lintDebug
```

Windows builds run `PairIt.ProtocolCheck`; Linux builds run monitor/identity checks.
CI builds all five platforms and includes Linux capture and graphical-startup checks.
Real calls, Bluetooth routing, background recovery and audio quality need device tests.

## Current release and validation

Current published builds are Mac/Windows/Linux **29**, Android **36** (GitHub APK) /
**37** (Google Play) and iOS **36**. Phone store availability depends on the testing
track and review status. Recent changes include per-phone Mac controls, earphone
media keys, phone volume from the Mac’s volume keys, Connect from the Mac, Low latency
playback, and banner plus app-open ads only.
PairIt is free with ads; there is no paid tier.

Mac and Ubuntu have owner testing. Physical Windows and iPhone acceptance remain
outstanding. CI covers builds, protocol/state regressions and isolated Linux audio
routing; it does not establish acoustic latency or Bluetooth reliability on every
device. See [release notes](https://github.com/Json604/pairIt-download/releases)
for platform-specific changes and limitations.

## Source map

| Directory | Purpose |
| --- | --- |
| `android/`, `ios/` | Native phone receivers and controls |
| `mac/`, `apple/` | Mac companion/driver and shared Apple code |
| `windows/PairIt.Core/` | Shared Windows/Linux sessions, protocol and updater |
| `windows/PairIt.Windows/`, `linux/` | Desktop UI and platform audio backends |
| `reports/` | Optional server for account-free public issue reports |
| `site/` | Website (pairit.kartikey.xyz); downloads link to GitHub Releases |
| `scripts/`, `.github/workflows/` | Builds, packaging and automated checks |
| `release/` | App configuration and published update metadata |

## Contributing and licensing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull requests, and
[SECURITY.md](SECURITY.md) for private vulnerability reports. PairIt’s original
source is [MIT-licensed](LICENSE). Bundled third-party libraries, SDKs, fonts and
adapted driver code retain their own licenses; the MIT license does not replace
those terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Official signing keys and production service credentials are not
required for local Preview builds and are never included in source.

## Releases and contributions

Phone update notices open the official store or release page. Desktop apps check
automatically and Settings supports an immediate check. From desktop build22,
Download & install verifies the signed download, exits cleanly and reopens the
updated app. Downloads are cancellable; installation is user initiated and stops
sharing. Mac uses Sparkle with EdDSA signatures and Developer ID verification.
Windows/Linux verify a pinned ECDSA signature plus package size/SHA256; Linux
.deb installation requests system authorization. Portable apps require a dedicated
writable folder and retain the previous folder for recovery. Pairing/settings
remain outside app files. Older desktop builds need one manual upgrade.
Google Play decides eligibility for each testing/production track.
Direct APK updates must match both package ID and signing certificate.

See [RELEASING.md](RELEASING.md) for the maintainer publication procedure.
