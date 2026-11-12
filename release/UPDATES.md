# Update notices and release maintenance

Update checks ship in Android code 14, iOS build 12, Mac build 10 and Windows
preview 6. Older installed binaries cannot acquire a checker remotely: install
one of these or a later build once. Checks are notices and trusted download links,
not a silent executable replacement service. The notice cannot be permanently
dismissed; it disappears after updating or after a successful feed check withdraws
that release. Offline launches preserve the cached notice. Audio never stops and
no full-screen prompt, background notification spam or forced restart is used.

## Availability and installation

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

## Public feed

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
