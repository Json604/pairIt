# PairIt

Computer audio through the headphones on your phone.

PairIt has two features: **Audio relay** and **Listen together**. Native companions
for Mac and Windows send encrypted local audio to Android and iPhone. Pair up to
four phones, each with its own headphones. No PairIt account or cloud audio server
is required.

[Website and setup](https://pairit.kartikey.xyz) ·
[Downloads](https://pairit.kartikey.xyz/downloads.html) ·
[Desktop releases](https://github.com/Json604/pairIt/releases)

## Availability

- **Mac:** universal Apple Silicon/Intel app, macOS 14.2+. Distribution builds are
  Developer ID signed and notarized. The included audio-output installer needs
  administrator approval on first setup. Existing working drivers need no reinstall.
- **Android:** Android 10+, available to invited Play internal testers; build 15 has been submitted for closed testing. Public production access still requires the closed test and Google approval.
  The separate Preview APK can coexist with the Play app and uses test ads.
- **iPhone:** iOS 17+, build 13 submitted for App Review; public release awaits approval. Simulator UI and transport
  checks are complete; physical iPhone audio validation remains pending.
- **Windows:** x64 preview. Extract the entire ZIP before running PairIt.exe.
  Native Windows playback testing and Microsoft Store distribution remain pending.

Store upload is not store approval. Use the website for current availability.

## Listen

1. Install the computer companion and phone app. Keep both on the same local network.
2. Connect your headphones to the phone. On Mac, finish audio-output and capture setup.
3. Open pairing on the computer, then scan its QR code or paste the full pairing link
   in the phone app. Keep pairing links private.
4. Confirm the computer and choose Start audio. Choose Computer or Phone explicitly.
5. For shared listening, pair each listener's phone with the same companion.

Android has regular ongoing notification actions and a Quick Settings tile.
Notification permission and operating-system dismissal/background rules apply.
Headphone play/pause retains Computer selection. iPhone supports media controls
and Home/Lock Screen shortcuts.

## Handoff and timing limits

The updated Mac holds its output during phone interruptions and unexpected receiver
loss, preventing automatic speaker restoration. Computer media can continue silently;
pause it in the player if needed and return using PairIt. Universal Mac player pause
and automatic return from desktop Play are not implemented.

Windows uses public GSMTC controls for supported media players. It does not mute
local Windows speakers or provide the Mac driver's video compensation. iPhone uses
explicit return after background suspension. Calls and missing outputs must not
force playback to an unintended output.

The Mac audio driver reports downstream presentation latency so compatible video
players can align video. Bluetooth still adds physical delay for live monitoring,
games and calls. Different listeners can hear different delays; this is not a promise
of synchronized multiroom sound or arbitrary multi-headphone Bluetooth support on
one phone.

## Build

Use Xcode on macOS for Apple apps, Java 21 and Android SDK/build-tools 36 for Android,
and the pinned .NET SDK 10.0.403 for Windows. Build scripts do not install or replace the Mac driver.

Clone the source first:

```sh
git clone https://github.com/Json604/pairIt.git
cd pairIt
```

For Android, set `ANDROID_HOME` to your SDK location (or use
`android/local.properties` with `sdk.dir=...`) and install platform/build-tools 36.
The Gradle wrapper downloads the required Gradle version. Use the Preview package
to keep a development build separate from an installed Play version:

```sh
PAIRIT_ANDROID_UI_PREVIEW=1 bash scripts/build-android.sh
```

Run the other commands on their supported build hosts:

```sh
bash scripts/build-android.sh
bash scripts/build-mac.sh
bash scripts/build-ios.sh simulator
bash scripts/build-ios.sh device
bash scripts/build-windows.sh
```

On Windows, use `powershell -File scripts/build-windows.ps1` instead of the shell
script. On macOS, select a full Xcode installation and install its iOS simulator
runtime before building. The `device` command produces an unsigned app, not an
installable App Store package.

Build outputs are written under `artifacts/`. Android's default output is
`audio-relay-debug.apk`; Mac's is `PairIt.app`; iPhone outputs are labeled
Simulator or Unsigned. Windows defaults to `artifacts/feature-preview/windows/win-x64/`.

The first Android development build creates a local debug key. Release signing
requires the owner's existing private upload key, which is not in this repository.
Apple distribution also requires your own signing environment. Local development
outputs are not necessarily signed/notarized distribution artifacts.

Google Mobile Ads and UMP support one phone banner and an occasional post-pairing
interstitial. Debug builds use dedicated test inventory. Release requests are consent
gated; account approval, consent setup and live fill are separate requirements.
Ads do not receive relayed audio or pairing credentials. There are no desktop ads.

## Updates

Update-capable builds check for new releases and show a persistent Get update notice.
Google Play determines update eligibility for Play installations; APK releases are
matched by package and signing certificate. iPhone notices open the App Store.
Mac and Windows notices open the official GitHub release download. The notice
remains until the installed build catches up; it never stops listening or silently
replaces executable files. The OS/store or user performs installation.

Checks run asynchronously on launch/return and at most every six hours during use.
Offline checks preserve a cached notice; a successful check removes withdrawn
releases. Older copies need one manual/store update to gain this checker. See
[release feed maintenance](release/UPDATES.md) before publishing future versions.

## Source and third-party notices

`android/`, `ios/`, `mac/` and `windows/` contain the native apps. Shared Apple styling
is in `apple/`; build and diagnostic tools are in `scripts/`. Historical utilities
are not necessarily part of the current product workflow.

PairIt's original code is available under the [MIT License](LICENSE).
Third-party files retain their own licenses: preserve the
[Apple audio-driver sample license](mac/driver/APPLE-LICENSE.txt),
[Chakra Petch font license](design/fonts/OFL.txt), and
[Windows dependency notices](windows/licenses/DEPENDENCIES.md). Bundled SDKs and
runtime dependencies remain subject to their respective terms.

Signing keys, pairing credentials, local accounts, generated artifacts and private
rollout records are excluded. Some owner release-packaging scripts expect those
local records; they are not required for the development builds above.

## Contributing and forks

Open an issue describing the platform, app version and steps to reproduce. Never
post pairing codes, private keys, device identities or raw diagnostic captures
containing personal data. Keep audio timing changes separate from UI changes and
explain how playback, background behavior and output switching were checked.

For your own distribution, use your own package/bundle identities, signing keys,
AdMob configuration, privacy policy and support contact. The checked-in AdMob IDs
are public identifiers for the official app, not credentials or a monetization
configuration for forks. Development builds use Google test ads. Replace the
update-feed URL and official download links before distributing a fork so it
does not direct users to incompatible official builds. See
[update feed maintenance](release/UPDATES.md).
