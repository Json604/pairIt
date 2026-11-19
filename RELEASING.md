# Releasing PairIt

Maintainer-only distribution procedure. Contributors normally use the local build
commands in [README.md](README.md); release signing credentials are not included.

## Release an update, step by step

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

   Desktop installation also requires the signed `release/installers.json` for
   Windows/Linux and `release/mac-appcast.xml` for Sparkle. Use
   `scripts/sign-installer-feed.py` and `scripts/create-mac-appcast.py` with the
   existing private release signing keys. Never replace the trust keys shipped in
   installed apps as part of an ordinary release. Verify asset hashes, architecture
   and signatures, then publish these feeds in the downloads repository only after
   their assets are public. Preserve unchanged platform entries.

8. **Update and deploy the website.** Its source is `site/` in this repository,
   deployed by its own Vercel project (root directory `site`) to
   `pairit.kartikey.xyz`; Vercel rebuilds only when `site/` changes on `main`.
   Update `site/index.html` and `site/downloads.html` to exact new asset URLs and
   correct versions, and point the legacy `/downloads/*` redirects in
   `site/vercel.json` at the new release. Never commit binaries to `site/`. Update
   favicon/brand assets when changed, including cache-version suffixes. Regenerate
   policy/setup pages with `python3 scripts/build-pairit-site.py` after changing
   `scripts/prepare-play-content.py`. Merge only after the release assets are public;
   never point a public button to a draft or local file.
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

Desktop installer release signing and staged rollout: see `docs/desktop-installer-rollout.md`. Publish signed installer metadata and the Mac appcast before advancing the ordinary update notice feed. Never commit release signing private keys.
