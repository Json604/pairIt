# Desktop in-app installation rollout

User authorized a manually installed bootstrap release, then a second release to test Download & Install. Do not publish the second release until the owner confirms installing the first.

- [x] Website: Linux Intel/AMD x64 and ARM64 equally visible; Mac Universal; Windows x64.
- [x] Mac: pinned Sparkle, EdDSA update signatures plus Developer ID/notarization; user-initiated installation.
- [x] Windows/Linux: pinned public key verifies signed installer metadata, SHA256 and size before extraction/execution; exact platform/architecture selection; no private signing key shipped.
- [x] Installer: graceful exit, preserve external pairing/settings, recover failed replacement, no silent elevation. Linux .deb uses system authorization; portable folder must be writable and isolated.
- [x] Progress, cancel, error and restart UI; malformed/tampered metadata, wrong architecture and failed installation tests.
- [x] Baseline release22: signed/notarized Mac; complete Windows x64 ZIP; Linux amd64/arm64 packages and archives; website/feed published only after verification.
- [x] Owner confirms baseline22 installed on Mac and Linux; authorized23 for all desktops.
- [x] Publish test release23 for all desktops after owner confirmed Mac/Linux22.
- [x] Owner confirmed in-app installation/relaunch works on physical Mac and Linux. Windows acceptance remains pending.

Private ECDSA signing key: ~/.config/pairit/desktop-update-signing.pem (never commit or log). Mac Sparkle key belongs in login Keychain. Public keys are intentionally distributable. Existing phone builds remain unchanged. Do not launch phone audio simulators or overwrite the owner's installed Mac app during development.

Website labels published as Sites version36 (source67449d5): both homepage and downloads page offer Linux Intel/AMD x64 and ARM64; Mac Universal and Windows Intel/AMD x64 are explicit. Existing release links retained until bootstrap22 is verified.

## Release procedure
1. Keep the two private signing keys outside the repository: the P-256 PEM above and Sparkle Keychain account `dev.pairit.updates`. Public counterparts in `release/` must remain pinned across updates.
2. Build the desktop apps with increasing file/bundle build numbers. Build scripts write `pairit-files.json`; Windows/Linux update ZIPs must have a `PairIt/` root (`scripts/package-update-zip.py`). Include complete self-contained runtimes and license files.
3. Mac: keep the signed driver package, run `scripts/sign-mac-distribution.py APP --identity IDENTITY`, archive/export through Xcode for notarization, staple and verify, then create the ZIP/DMG. `scripts/create-mac-appcast.py ZIP --build N --output APPCAST` signs the ZIP with the PairIt Keychain account.
4. Create a JSON array of Windows/Linux targets with platform/architecture/kind/build/version/url/file. `scripts/sign-installer-feed.py ENTRIES OUTPUT` computes SHA256/size and signs the manifest. The local file paths are removed from the published output.
5. Test malformed signatures, mismatched architectures/builds, unsafe archives and cancelled/failed downloads. Run `scripts/installer-worker-check` in isolated Linux with a signed local next-build fixture; never publish that fixture just for automated tests.
6. Publish binaries/checksums first, verify GitHub asset digests, then publish `release/installers.json`, `release/mac-appcast.xml`, and finally the updated ordinary `release/updates.json` notice feed in the public download repository. Update website links only after assets are public.
7. Never copy source/private keys into the public download repository. Keep phone versions unchanged for this desktop-only rollout.

Portable replacement retains a previous app folder; rollback covers a failed filesystem replacement or failed launch, not arbitrary crashes after a successful process launch. Linux package-manager failures use the system package manager's recovery; pairing/settings stay separate. Physical Windows installation and desktop Linux authorization still require acceptance testing.

Verification: final source d2c26d7, final CI43655960981; evidence in artifacts/updater-bootstrap. Linux real-worker tamper rejection and valid22→local23 install/relaunch passed with a separate profile; Linux package21→22 and graphical startup passed. Mac22 notarized/stapled and EdDSA verified. The local23 fixture predates the Linux handoff fix and MUST NOT be published; rebuild23 from final source after owner confirmation.
