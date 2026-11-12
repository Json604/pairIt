# PairIt

Computer audio through the headphones on your phone.

PairIt has two features: **Audio relay** and **Listen together**. Native companions
for Mac and Windows send encrypted local audio to Android and iPhone. Pair up to
four phones, each with its own headphones. No PairIt account or cloud audio server
is required.

[Website and setup](https://pairit.kartikey.xyz) ·
[Downloads](https://pairit.kartikey.xyz/downloads.html) ·
[Desktop releases](https://github.com/Json604/pairIt/releases)

[Availability](#availability) · [Setup](#listen) · [Build](#build) ·
[Troubleshooting](#platform-setup-and-troubleshooting) ·
[Release maintenance](#release-maintenance) · [Contributing](#contributing-and-forks)

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
[release maintenance](#release-maintenance) before publishing future versions.

## Source and third-party notices

`android/`, `ios/`, `mac/` and `windows/` contain the native apps. Shared Apple styling
is in `apple/`; build and diagnostic tools are in `scripts/`. Historical utilities
are not necessarily part of the current product workflow.

PairIt's original code is available under the [MIT License](LICENSE).
Third-party files retain their own licenses: preserve the
[Apple audio-driver sample license](mac/driver/APPLE-LICENSE.txt),
[Chakra Petch font license](design/fonts/OFL.txt), and
Windows dependency license files in `windows/licenses/`. Bundled SDKs and
runtime dependencies remain subject to their respective terms.

Signing keys, pairing credentials, local accounts, generated artifacts and private
rollout records are excluded. Store packaging tools may require locally generated listing assets and verification
records; they are not required for the development builds above.


## Platform setup and troubleshooting

### Windows

Extract the complete ZIP and run `PairIt.exe`; keep its DLLs, fonts, licenses and
README together. Closing the window keeps PairIt in the notification area; choose
Exit PairIt to stop it. Select the render output your computer apps actually use,
then choose Start sharing. If asked, allow the app through Windows Firewall on
your trusted private network. PairIt listens on TCP 5002; do not port-forward it.

Windows currently uses manual address selection rather than Bonjour discovery.
Choose a reachable local address under Listen together and paste the pairing code
into the phone. If the address changes, update the phone's manual host or pair
again. An unreadable saved identity must not be deleted as routine troubleshooting:
that invalidates existing pairings.

WASAPI captures the chosen output; local speakers keep playing. For silent local
playback, configure a separately installed virtual render device for your apps
and select it as PairIt's source. PairIt does not include a Windows virtual driver.
Supported mixes are 44.1/48 kHz mono/stereo float32 or PCM16/24/32. Protected media
may be unavailable. If the source disappears, select an available source and start
sharing again.

Supported media players can respond to Windows' best-effort pause request. This
is not universal multipoint: browser tabs, games and calls may not expose compatible
media controls, and Windows selects the current media session. PairIt never sends
an automatic Play command. iPhone requires an explicit return to computer audio.

### Mac driver

The companion uses a process tap to capture computer audio and a HAL output driver
to report downstream latency to compatible players. The driver itself contains no
networking or recording. It is adapted from Apple's audio-server-driver sample;
its separate license remains in `mac/driver/APPLE-LICENSE.txt`.

`bash scripts/build-driver.sh` builds a universal driver and development installer.
Installing requires administrator approval and briefly restarts system audio.
Build scripts do not install it. Keep an existing working driver unless a release
specifically requires replacement.

To uninstall, quit PairIt, select your normal output in macOS Sound settings, then
run `sudo bash scripts/uninstall-driver.sh`. This also restarts system audio. The
driver path is `/Library/Audio/Plug-Ins/HAL/AudioRelayOutput.driver`.

### Connections and USB

Start with both devices on the same trusted Wi-Fi network. Check local-network
permissions, firewall rules, guest-network isolation and VPN routing if connection
fails. QR codes and pairing links contain credentials—keep them private.

USB means OS-provided networking, not USB Audio Class or an ADB connection.
Android USB tethering can provide a network to Windows; Android-to-Mac USB
networking is not generally supported. iPhone Personal Hotspot depends on carrier
support, trust approval and the required Apple software on Windows. Hotspot may
use cellular data. Choose the actual reachable USB network address explicitly;
connecting a cable alone does not establish the route. Clear manual address
overrides when returning to Wi-Fi.

### Dependencies

Android uses Google Mobile Ads, UMP, Play in-app updates and the Google code scanner.
iOS resolves its SDK packages through Xcode. Consult the checked-in Gradle and Swift
package configuration for exact versions. Fonts use the SIL Open Font License.
Windows locks NAudio.Core/NAudio.Wasapi 2.2.1 and bundles .NET/Windows Desktop runtime
10.0.14; preserve all MIT licenses and third-party notices in `windows/licenses/`.
No third-party virtual audio drivers are redistributed.

## Release maintenance

Update checks ship in Android code 14, iOS build 12, Mac build 10 and Windows
preview 6. Older installed binaries cannot acquire a checker remotely: install
one of these or a later build once. Checks are notices and trusted download links,
not a silent executable replacement service. The notice cannot be permanently
dismissed; it disappears after updating or after a successful feed check withdraws
that release. Offline launches preserve the cached notice. Audio never stops and
no full-screen prompt, background notification spam or forced restart is used.

### Availability and installation

- Play-installed Android: Google Play AppUpdateInfo is authoritative for the
  signed-in account's testing track, rollout, compatible device and available build.
  Get update opens Play. A sideloaded production package also tries Play eligibility,
  then falls back to matching APK metadata if Play cannot offer an update.
- Direct Android APKs, including the official Preview package: match bundleID,
  signing certificate SHA-256 and minimum SDK. Re-signed third-party builds cannot
  install our APK without a signature conflict and are not offered incompatible
  files. Publish a separate entry for each officially supported signing identity.
  Never ask users to uninstall or lose pairing data to resolve this mismatch.
- iPhone: publish the iOS feed entry only after the release is actually available
  in the supported App Store regions. Get update opens PairIt's App Store page.
  An uploaded/TestFlight-only build is not a public App Store release. TestFlight
  also supplies its own build-update mechanism. Do not advertise a newer internal
  build to public users through this feed.
- Desktop: publish the exact signed/notarized Mac download and full Windows ZIP
  first. Get update opens its GitHub release. Quit before replacing the installed
  app; preserve preferences/identity and the Mac driver. Windows requires the whole
  extracted folder, not just PairIt.exe. No automatic installer is implemented.

### Public feed

Source: `release/updates.json` on main. Clients fetch the fixed raw.githubusercontent
URL using HTTPS. No query IDs, credentials, audio or telemetry payloads are sent.
Only versioned GitHub releases under Json604/pairIt are accepted for desktop/APK
links; iPhone accepts only the existing App Store ID. Feed schema is 1; max 64 KiB
and 100 entries. Unknown schema/network failures preserve cached updates. Feed
contains only published, reachable releases, not builds in preparation.

Each entry requires platform, bundleID, monotonically increasing integer build,
version, and url. Apple/Windows require minimumOS; Android requires minimumSDK
and lowercase signerSHA256 of the APK signing certificate (not its file hash).
The Windows build counter is the fourth FileVersion component; do not reset it
when marketing version changes. Apple uses CFBundleVersion, Android versionCode.
Increment all relevant counters before packaging a release.

Publishing order:

1. Build and verify artifacts/signatures; retain rollback artifacts.
2. Upload assets or complete store rollout. Verify the download is available.
3. For APKs verify the package, versionCode and signer using apksigner/aapt.
4. Add/update matching feed entries; remove withdrawn releases. Never point to
   mutable "latest" URLs or raise the advertised build before publication.
5. Run `python3 scripts/check-update-feed.py`; commit/push feed to main only after
   it passes. Review the raw URL from outside the local checkout.
6. Verify installed older update-capable apps show Get update and that updated
   builds hide it. Do not publish fake high build numbers for UI testing.

Store availability can vary by region/account. Play's native eligibility avoids
that issue. For iOS publish conservatively after intended-region rollout completes.
Checks on app activation are throttled to six hours, with five-minute retry after
network errors. OS background limits apply; this is not an always-running service.

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
[release maintenance](#release-maintenance).
