# PairIt

Computer audio through the headphones on your phone.

PairIt sends audio from a Mac or Windows computer to Android or iPhone over an
encrypted local connection. Listen on your own, or pair up to four phones, each
with its own headphones. No PairIt account or cloud audio server is required.

[Website](https://pairit.kartikey.xyz) ·
[Downloads](https://pairit.kartikey.xyz/downloads.html) ·
[Releases](https://github.com/Json604/pairIt/releases)

## Availability

| Platform | Requirements | Status |
| --- | --- | --- |
| Mac | macOS 14.2+, Apple Silicon or Intel | Signed and notarized downloads |
| Android | Android 10+ | APK downloads and invited Play internal testing; closed-test review pending |
| iPhone | iOS 17+ | Submitted for App Review; public release and physical-device audio validation pending |
| Windows | Windows 10 build 19041+, x64 | Unsigned preview; native playback validation pending |

Store submission does not mean approval. Check the downloads page for current
availability. The separate Android Preview APK can coexist with the Play app and
uses test ads.

## Setup

1. Install the computer companion and phone app. Keep both on the same local network.
2. Connect your headphones to the phone.
3. On Mac, complete audio-output setup and allow system audio capture. On Windows,
   extract the entire ZIP, select the output your apps use, and start sharing.
4. Open pairing on the computer. Scan its QR code or paste the full pairing link
   in the phone app, then confirm the computer. Updated companions show **Phone paired**
   before audio starts. If the computer is offline, the phone keeps the code saved
   and tells you confirmation is unavailable.
5. Choose **Computer** to listen or **Phone** to return to phone audio. For shared
   listening, pair each listener's phone with the same computer.

Keep pairing codes private: they grant access to shared computer audio. Forgetting
a computer on one phone does not revoke copies of its code on other phones.

Android supports notification controls and a Quick Settings tile. Allow notifications
to keep the source switch available while Phone is selected. iPhone supports media
controls and Home/Lock Screen shortcuts. Headphone play/pause keeps Computer selected;
it pauses this phone's live relay, while the computer player may keep progressing.

Choose **Phone headphones** or **Computer speakers** in the computer companion to
change where computer audio plays. Updated phone apps show the destination and let
you change it too. This keeps live connections and saved pairings; the choice applies
to all listeners, and paused phones stay paused. **Stop sharing** ends live sessions;
**Forget this computer** removes a phone’s saved pairing.

## Playback and connection limits

- **Mac:** the companion holds its output during phone interruptions and unexpected
  connection loss. Media can continue silently. Return through PairIt, or choose
  **Mac speakers** on the computer; this keeps its phone connections. Universal player pause is not implemented.
- **Windows:** local speakers keep playing. For silent local output, use a separately
  installed virtual render device. Supported players can respond to a best-effort
  pause request; PairIt never sends automatic Play. Windows has no bundled virtual
  driver or Mac-style video compensation.
- **Timing:** the Mac driver reports downstream latency to compatible video players.
  Bluetooth still adds delay for games, live monitoring and calls. Different listeners
  can hear different delays; shared listening does not guarantee synchronized outputs.
- **iPhone:** returning after background suspension requires an explicit action.
  Simulator checks do not establish physical-device audio quality.
- **Networking:** guest Wi-Fi isolation, VPNs, firewalls and local-network permissions
  can block connections. PairIt uses TCP 5002; do not port-forward it. Windows uses
  manual address selection. Clear manual host overrides when changing networks.
- **USB:** supported OS tethering/hotspot links can carry the same network connection.
  A cable alone is insufficient. Android-to-Mac USB networking is not generally
  supported; iPhone Personal Hotspot depends on carrier and platform support and
  may use cellular data.

The Mac audio-output installer needs administrator approval and briefly restarts
system audio. Keep an existing working driver unless a release requires replacement.
To uninstall it, quit PairIt, select your normal output, then run
`sudo bash scripts/uninstall-driver.sh`. This also restarts system audio.

## Build

Use full Xcode on macOS for Apple apps, Java 21 and Android SDK/platform/build-tools
36 for Android, and .NET SDK **10.0.404** for Windows. Set `ANDROID_HOME` or
`android/local.properties` with `sdk.dir=...` for Android.

```sh
git clone https://github.com/Json604/pairIt.git
cd pairIt

PAIRIT_ANDROID_UI_PREVIEW=1 bash scripts/build-android.sh
bash scripts/build-mac.sh
bash scripts/build-ios.sh simulator
bash scripts/build-ios.sh device
bash scripts/build-windows.sh
```

Run each command on a supported build host. On Windows, use
`powershell -File scripts/build-windows.ps1`. The Android wrapper downloads its
pinned Gradle version. Remove `PAIRIT_ANDROID_UI_PREVIEW=1` to build the regular
Android package instead.

Outputs go under `artifacts/`. The iOS `device` build is unsigned; Apple distribution
requires your own signing environment. Android release signing requires the existing
private upload key. Development builds use test ads. Build scripts do not install
or replace the Mac audio driver.

## Checks

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check-update-feed.py --offline
python3 android/tests/verify-core.py
```

On macOS, run the synthetic network and handoff checks:

```sh
python3 scripts/verify-feature-server.py
python3 scripts/verify-feature-gateway.py
python3 scripts/verify-receiver-handoff.py
```

Windows builds run `PairIt.ProtocolCheck`. Android changes should also pass
`./gradlew lintDebug` from `android/`. CI builds all four platforms and runs the
available automated checks. Real Bluetooth, calls, output switching and background
playback still need device testing.

## Privacy and security

PairIt does not record audio. Pairing authenticates the computer's certificate and
uses TLS for audio transport. Phone apps contain Google ads; advertising, consent
and update requests are separate from the local audio connection. See the
[privacy policy](https://pairit.kartikey.xyz/privacy.html) for details.

Report vulnerabilities through [private security reporting](https://github.com/Json604/pairIt/security/advisories/new),
or email kartikey060105@gmail.com if that is unavailable. Never post pairing codes,
private keys or personal diagnostic captures in an issue. Stop sharing if a pairing
code leaks; there is currently no per-phone revocation control. Do not delete an
unreadable saved computer identity as routine troubleshooting—it invalidates pairings.

## Updates and releases

Update notices open the official store or GitHub release; they do not install
executables or interrupt playback. Successful checks are spaced six hours apart;
failed requests can retry after five minutes. Offline launches preserve cached notices.
Google Play controls eligibility for Play installations; direct APK updates must
match the package and signing certificate.

Before publishing, increment the affected build counters, build in a clean staging
directory, verify signatures and device behavior, and publish the downloads first.
Then update `release/updates.json` and run `python3 scripts/check-update-feed.py`.
Use versioned official release URLs; advertise iOS updates only after App Store
availability is confirmed. Source changes do not update previously published binaries.

## Contributing

Open an issue with the platform, app version and steps to reproduce. Keep changes
focused and include the relevant build/test results. Distinguish automated checks
from actual device testing. Do not commit signing material, pairing credentials,
account records or generated builds.

Edit `scripts/prepare-play-content.py` to change generated help/privacy text, then
regenerate it. Use `scripts/generate-ios-project.py` when changing Xcode source
membership. Preserve dependency pins, checksums and third-party notices.

Forks should use their own package identities, signing keys, ad configuration,
privacy policy, support contact and update feed. The checked-in AdMob IDs are public
identifiers for the official app, not credentials or configuration for fork releases.

## License

PairIt's original code is [MIT licensed](LICENSE). Third-party files retain their
own licenses, including the [Apple driver sample](mac/driver/APPLE-LICENSE.txt),
[Chakra Petch fonts](design/fonts/OFL.txt), and dependencies in `windows/licenses/`.
