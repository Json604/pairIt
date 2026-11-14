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
same LAN can appear too. After pairing a computer, tap a nearby phone to invite it
to listen to that same computer (Mac, Windows or Linux). Keep **Together** open on
both updated phones, compare the displayed code, then **Accept** on both. The
recipient verifies the computer before saving its pairing and starting audio.
**Share app** is separate, for someone without PairIt. Older phones must update to
receive invitations. Invitations expire after 65 seconds and are cancelled when
Together closes or the app leaves the foreground.

Invitations use fresh P-256 ECDH keys and AES-256-GCM encryption; no pairing token
is advertised through Bonjour. Comparing the code on both phones authenticates
the exchange. Do not accept mismatching codes or unexpected invitations. Each
accepted phone receives access to the same computer; the existing four-listener
limit still applies.

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

Report vulnerabilities through [email](mailto:kartikey060105@gmail.com)
or email kartikey060105@gmail.com. Do not post pairing codes, keys or private captures.

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

## Current preview changes

Preview 13 includes phone-audio interruption recovery across network changes,
acknowledged desktop Pause audio / Resume audio controls with bounded loading
feedback, and matching controls on Android and iOS. Desktop commands are negotiated
with compatible receivers; older phones continue using their existing controls.
Android and iOS open directly into Connect. The demo tour and its Settings entry
have been removed. Shared native UI components and the nearby-phone orbit remain.

Available phones are PairIt devices advertising while Together is open on the
reachable local network.
Windows/Linux are build- and protocol-tested; physical runtime acceptance and
physical iPhone testing remain separate from those checks. GitHub preview releases
do not update Google Play or App Store installations.

## Releases and contributions

Update notices open the official store or release page; they do not install files
or stop audio. Mac, Windows and Linux check automatically on opening/foreground and
periodically, with visible update notices; Settings supports an immediate check.
Desktop installation remains explicit: quit PairIt, then install the newer package
or replace the portable application files. Google Play decides eligibility for each testing/production track.
Direct APK updates must match both package ID and signing certificate.

### Release an update, step by step

A source push, a downloadable release, and a store rollout are three separate steps.
Follow this sequence after changing any phone or computer app.

Source and development history stay in `Json604/pairIt`. Public distribution lives
in [Json604/pairIt-download](https://github.com/Json604/pairIt-download): release
binaries, checksums, release notes, and `release/updates.json`. It has a separate,
fresh Git history. Never mirror or push the source repository to the downloads
repository. Never upload a workspace/archive containing keys, local pairing state,
logs, provisioning profiles, or private configuration. Use an explicit file list.
Public signing certificates, certificate fingerprints and AdMob unit IDs are
identifiers, not signing keys or account credentials.

1. **Check the affected platforms.** For a UI, icon or protocol change, check every
   platform that uses it. Run the relevant checks above, build, and test the actual
   release candidate. Test pairing, output switching, network loss/reconnect and
   interruption recovery. Keep previews labelled as previews where hardware
   acceptance is incomplete.
2. **Choose unused version/build numbers.** Check existing GitHub releases and
   uploaded store builds, including drafts. Increment the affected counters below.
   Never reuse a store build number for a changed binary. Keep package/bundle IDs
   and signing identities unchanged so installed apps can update.

   | App | Version source |
   | --- | --- |
   | Android | `release/google-play/release.json`: `version_name`, `version_code` |
   | iPhone | `release/apple/release.json`: `version_name`, `build_number` |
   | Mac | `mac/Info.plist`: `CFBundleShortVersionString`, `CFBundleVersion` |
   | Windows | `windows/PairIt.Windows/PairIt.Windows.csproj`: `Version`, `FileVersion` |
   | Linux | `linux/PairIt.Linux/PairIt.Linux.csproj`: `Version`, `FileVersion` |

   Regenerate phone configuration after changing its version or name:

   ```sh
   python3 scripts/prepare-play-content.py
   python3 scripts/generate-ios-project.py
   ```

3. **Build fresh distribution files in an isolated folder.** Do not rename an old
   download and treat it as a new build. Inspect the built version, visible name,
   bundled icon and signature—not just the source files.

   - **Android:** run `python3 scripts/build-play-release.py --internal --output-dir
     artifacts/release-candidate/android`. The existing upload key must be available.
     This creates and validates the AAB plus a signed production-package APK; its
     `-testing.apk` filename does not mean test ads. `--internal` permits documented
     preview/configuration blockers; resolve those and omit it for a production
     candidate. Build the separate Preview APK with `PAIRIT_ANDROID_UI_PREVIEW=1
     bash scripts/build-android.sh`, then copy it immediately to the release folder.
     Never upload the Preview/debug package to the existing Play app.
   - **iPhone:** use Xcode scheme `AudioRelay`, a generic iOS device destination,
     and the existing team for app and widget targets. Product → Archive, then
     Organizer → Validate App → Distribute App → App Store Connect → Upload.
     `scripts/build-ios.sh device` is an unsigned build check, not an uploadable IPA.
   - **Mac:** build with `scripts/build-mac.sh`, then apply Developer ID distribution
     signing with hardened runtime and timestamp. The build script alone uses
     ad-hoc signing. If the audio driver has not changed, preserve the previously
     signed/notarized installer; if it changed, distribution-sign its driver and
     installer and notarize them too. Notarize the new app through Xcode’s
     Developer ID archive export or `notarytool`; wait for acceptance, then staple
     its ticket. Never publish merely because upload succeeded. Verify:

     ```sh
     codesign --verify --deep --strict /path/to/PairIt.app
     xcrun stapler validate /path/to/PairIt.app
     spctl --assess --type execute --verbose=2 /path/to/PairIt.app
     ```

     Package the verified app in a DMG with an Applications shortcut and/or a ZIP.
     Mount/extract the finished package and repeat verification on the app inside.
     See [Apple’s notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
   - **Windows:** run `scripts/build-windows.sh` (or the PowerShell equivalent).
     ZIP the **complete** published folder under
     `artifacts/feature-preview/windows/win-x64/`, including DLLs, runtime, fonts,
     instructions and licenses. `PairIt.exe` alone is not the distribution.
   - **Linux:** run `scripts/build-linux.sh` for x64 and again with
     `PAIRIT_LINUX_RID=linux-arm64`. Archive each complete output folder under
     `artifacts/linux/` separately, preserving executable permissions and licenses.
     Check the launcher icon and name as well as the binary.

4. **Commit and push the source.** Run `git diff --check`, review the diff and ensure
   generated files are current. Exclude credentials, builds and local logs. Commit,
   push and inspect CI. Record the exact source commit used for the artifacts.
5. **Create a new GitHub release draft in `Json604/pairIt-download`.** Use
   `gh release create <tag> --repo Json604/pairIt-download --draft --prerelease`
   for a preview. Choose a new tag, attach the newly built
   Mac/Windows/Linux/APK files, and include release notes with platform build numbers
   and known limitations. Generate `SHA256SUMS.txt` from the final packaged files
   and attach it. Verify uploaded asset hashes match locally. Mark testing releases
   as pre-releases. Publish the draft only after verification; do not overwrite old
   assets under an existing version. The main website downloads use these assets.
6. **Roll out phone store updates separately.**
   - **Google Play:** open the existing app, upload the new AAB to Internal testing,
     wait for processing, confirm its version, enter notes, review and roll out.
     Test the Play-installed build, then promote that same bundle to the existing
     closed Alpha track. Preserve testers and track configuration. Complete review
     and any Publishing overview step. Promote to Production only after required
     testing/production access and acceptance. Adding testers alone needs no new
     build: save their accounts and share that track’s opt-in link. Update the
     store name, screenshots, description, privacy and Ads/Data safety declarations.
     [Google’s release workflow](https://support.google.com/googleplay/android-developer/answer/9859348).
   - **App Store Connect:** wait for the uploaded build to process and test it on a
     physical iPhone through TestFlight. Select it on the editable App Store version.
     If the old version is already public, create a higher version; if a submission
     is in review, remove it before replacing its build. Update name, screenshots,
     What’s New, privacy disclosures and reviewer setup instructions. Add for Review
     and submit, then verify the resulting status. Release after approval according
     to the selected manual/automatic release setting.
     [Apple’s submission workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).
   Verify AdMob privacy messages before production; do not change
   `consent_messages_confirmed` merely to bypass a build warning. Store metadata
   changes and uploading a build do not by themselves update users’ installations.
7. **Update the app update feed only after downloads are available.** Edit
   `release/updates.json` with actual published builds, versions, versioned URLs and
   the matching Android certificate fingerprints. Do not advertise an iOS update
   before its public App Store listing is available. Run:

   ```sh
   python3 scripts/check-update-feed.py
   ```

   Copy only the validated `release/updates.json` into a separate clean checkout of
   `Json604/pairIt-download`, review its diff, and commit/push it there. Keep the
   source copy committed too; pushing the source alone does not publish the feed.
   The public endpoint is
   `https://raw.githubusercontent.com/Json604/pairIt-download/main/release/updates.json`.
   GitHub APK availability does not imply Google
   Play track availability; Play still controls eligibility and installation.
8. **Update and deploy the website.** Its separate checkout is
   `sites/paircove/` and is intentionally ignored by the app repository. Update
   `dist/index.html` and `dist/downloads.html` to exact new asset URLs and correct
   versions. Update favicon/brand assets when changed, including cache-version
   suffixes. Refresh legacy files in `dist/downloads/` and their checksums if those
   URLs remain supported. Regenerate policy/setup pages when their source changes.
   Publish the website through its existing hosting workflow; pushing this app repo
   does not deploy the website. Never point a public button to a draft or local file.
9. **Verify what users actually receive.** Follow the deployed website buttons,
   download and extract/mount the packages, and compare hashes, icons and versions.
   Check store rollout status separately. Confirm the update notification opens the
   right destination and that existing installations can update without losing
   pairing. Keep the previous release available for recovery; a store rollback
   generally needs another build with a higher build number.

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
