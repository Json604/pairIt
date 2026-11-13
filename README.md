# PairIt - AudioRelay

Listen to your computer through your phone’s headphones, wired output or speaker.
PairIt sends audio from Mac, Windows or Linux to Android or iPhone over an encrypted
local connection. Up to four phones can listen, with separate volume controls.
No PairIt account or cloud audio server is required.

[Website](https://pairit.kartikey.xyz) · [Downloads](https://pairit.kartikey.xyz/downloads.html) · [Releases](https://github.com/Json604/pairIt/releases)

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
2. Connect your headphones to the phone. Start sharing on the computer.
3. Scan the computer’s QR code in PairIt, or paste its pairing link. A valid scanned
   code verifies the computer and connects. Android and iPhone can also request
   pairing from a nearby Mac: compare the code on both screens and approve on the Mac.
   Windows and Linux use QR/link pairing for a new phone.
4. Start audio. Choose **This phone** or **Computer** to change the shared destination.
   Choose a local phone output from the output picker. **Refresh audio** clears the
   playback buffer if timing drifts.

**Connect** lists computers advertising PairIt, not all Wi-Fi devices.
**Together** lists other PairIt phones while their Together screen is open.
Simply installing PairIt does not make a device visible. Wired computers on the
same LAN can appear too. Tap a nearby phone to open the system share sheet, or use
**Share app** for someone without PairIt. Nothing is sent automatically.

Switching to Computer keeps live control connections and saved pairings; paused
phones stay paused. The destination applies to all listeners. **Disconnect** ends
one phone’s live session; **Stop sharing** ends the computer’s live sessions.
**Forget this computer** removes that phone’s saved credentials.

Android has notification controls and a Quick Settings tile. iPhone has system
media controls and Home/Lock Screen shortcuts. After calls or another phone app
interrupts playback, resume through PairIt or its available system controls.
Headphone play/pause controls this phone’s relay; the computer player may continue.

## Computer setup and limits

- **Mac:** complete the included audio-output setup and allow system audio capture.
  A connected, paused phone holds the relay output. When the last phone disconnects
  or times out, the Mac restores its previous output. The driver reports latency
  to compatible video players; it cannot remove Bluetooth latency for live audio.
- **Windows:** extract the entire ZIP and run `PairIt.exe`. Select the output your
  apps use. Local speakers keep playing unless you use a separately installed
  virtual render device. Supported players can respond to a best-effort pause;
  PairIt does not automatically press Play.
- **Linux:** install `pulseaudio-utils libx11-6 libice6 libsm6 libfontconfig1 libicu-dev
  xdg-utils`, extract the archive and run `./PairIt` as your normal desktop user.
  Use **Pair a phone** to select an output and start sharing after launching the app.
  Run `./install-desktop.sh` from its permanent folder to add a launcher.
  Local speakers keep playing unless you use a virtual sink. Closing the window
  stops sharing. Linux has no automatic player pause or video compensation.
- **Timing:** each phone/headphone combination adds its own delay. Shared listening
  does not guarantee synchronized outputs. Use one phone per listener; using two
  headphones on one phone depends on the phone’s own audio-sharing support.
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

PairIt does not record audio. Phone apps use Google ads; ad/consent requests,
Android scanner telemetry and update checks are separate from local audio.
See the [privacy policy](https://pairit.kartikey.xyz/privacy.html).
Encryption does not protect compromised endpoints or prevent every local-network
attack. Automated checks and source review are not a guarantee of zero vulnerabilities.

Report vulnerabilities through [private security reporting](https://github.com/Json604/pairIt/security/advisories/new)
or email kartikey060105@gmail.com. Do not post pairing codes, keys or private captures.

## Build and check

Use full Xcode on macOS for Apple builds, Java 21 and Android SDK/build-tools 36
for Android, and .NET SDK **10.0.404** for Windows/Linux. Configure `ANDROID_HOME`
or `android/local.properties` with `sdk.dir` for Android.

```sh
git clone https://github.com/Json604/pairIt.git
cd pairIt
PAIRIT_ANDROID_UI_PREVIEW=1 bash scripts/build-android.sh
bash scripts/build-mac.sh
bash scripts/build-ios.sh device
bash scripts/build-windows.sh
bash scripts/build-linux.sh
PAIRIT_LINUX_RID=linux-arm64 bash scripts/build-linux.sh
```

On Windows, use `powershell -File scripts/build-windows.ps1`. iOS simulator builds
use `bash scripts/build-ios.sh simulator`. Outputs are in ignored `artifacts/`.
The iOS device build is unsigned. Distribution requires your signing environment;
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

## Releases and contributions

Update notices open the official store or release page; they do not install files
or stop audio. Linux checks when requested. Other platforms cache notices and check
periodically. Google Play decides eligibility for each testing/production track.
Direct APK updates must match both package ID and signing certificate.

Before publishing, increment build counters, verify signed artifacts and device
behavior, then publish downloads. Update `release/updates.json` only for available
artifacts and run `python3 scripts/check-update-feed.py`. Do not advertise an App
Store download before its listing is available. Changing the display name preserves
existing package IDs and update identities.

For bugs, include OS, app version and reproduction steps. Keep changes focused and
include test results. Never commit signing material, pairing credentials or builds.
Edit `scripts/prepare-play-content.py` for generated help/privacy text and regenerate
it. Use `scripts/generate-ios-project.py` after changing Xcode source membership.
Preserve dependency pins, checksums and third-party notices. Forks need their own
package IDs, signing, ad settings, privacy policy and update feed. Checked-in AdMob
IDs are public identifiers for this official app, not credentials.

## License

Original code is [MIT licensed](LICENSE). Third-party licenses remain applicable,
including the [Apple driver sample](mac/driver/APPLE-LICENSE.txt),
[fonts](design/fonts/OFL.txt) and files in `windows/licenses/`. Linux packages include
notices in `licenses/`.
