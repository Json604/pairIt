# Desktop in-app installation rollout

User authorized a manually installed bootstrap release, then a second release to test Download & Install. Do not publish the second release until the owner confirms installing the first.

- [x] Website: Linux Intel/AMD x64 and ARM64 equally visible; Mac Universal; Windows x64.
- [ ] Mac: pinned Sparkle, EdDSA update signatures plus Developer ID/notarization; user-initiated installation.
- [ ] Windows/Linux: pinned public key verifies signed installer metadata, SHA256 and size before extraction/execution; exact platform/architecture selection; no private signing key shipped.
- [ ] Installer: graceful exit, preserve external pairing/settings, recover failed replacement, no silent elevation. Linux .deb uses system authorization; portable folder must be writable and isolated.
- [ ] Progress, cancel, error and restart UI; malformed/tampered metadata, wrong architecture and failed installation tests.
- [ ] Baseline release22: signed/notarized Mac; complete Windows x64 ZIP; Linux amd64/arm64 packages and archives; website/feed published only after verification.
- [ ] Owner installs baseline22.
- [ ] Publish test release23, then verify20/21→22 manual and22→23 in-app flows with owner.

Private ECDSA signing key: ~/.config/pairit/desktop-update-signing.pem (never commit or log). Mac Sparkle key belongs in login Keychain. Public keys are intentionally distributable. Existing phone builds remain unchanged. Do not launch phone audio simulators or overwrite the owner's installed Mac app during development.

Website labels published as Sites version36 (source67449d5): both homepage and downloads page offer Linux Intel/AMD x64 and ARM64; Mac Universal and Windows Intel/AMD x64 are explicit. Existing release links retained until bootstrap22 is verified.
