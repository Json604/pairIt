# Mobile group, sync and phone-name follow-up — 2026-11-15

Implemented locally; not published. Public desktop Preview23 and mobile32 remain unchanged.

- [x] Android/iOS pairing failure explains another phone may be connecting. Existing token validation and comparison approval remain intact.
- [x] Sound early/late controls: Android refreshes availability as output timing starts; iOS uses route availability instead of waiting for an estimate. Mac retains its primary-listener video correction. Windows/Linux change each phone's actual audio prefill in 10 ms steps, without dropping TLS. Corrections are bounded; advancing audio beyond the available buffer is impossible and reducing prefill may cause stutter. Reset restores automatic timing.
- [x] Foreground phone presence and invitations work on every tab. Background, camera/ad/dialog conflicts still suppress unsafe prompts. Explicit comparison-code approval remains required.
- [x] Invited guests retain a joined-group state, see Leave group, and cannot host or accept another invitation before leaving. Explicit stop/disconnect clears membership; saved pairing remains.
- [x] Computer taps and saved-PC Connect check bounded pinned-TLS occupancy. Occupied computers show connected phone labels and direct the user to request an invitation. Unknown/older companions fall back to the existing connection flow. Discovery and names remain display hints, not authentication.
- [x] Phone labels use the OS device name where available, in foreground discovery, the phone's own label, authenticated desktop connection labels, and Mac pairing requests. Named requests bind the name into the comparison transcript; old companions receive legacy requests. iOS 16+ normally returns generic iPhone without Apple's device-name entitlement; no entitlement/signing profile changed.
- [x] Local privacy source and bundled Android privacy text updated for foreground name discovery. Hosted privacy must be updated with the next release.

## Verification

Evidence logs: `artifacts/mobile-group-*.log`; local app builds under `artifacts/mobile-group/` and Android's Preview debug output.

- Android Preview compile + lint; iOS simulator compile only (app not launched).
- macOS universal app compile/ad-hoc signature, Windows cross-compile, Linux compile.
- Android and Swift presentation-timing checks: earlier/later correction direction, bounded prefill, mixed outputs, group/solo timing and rate limits.
- Actual Java/Swift invitation crypto and TCP interoperability in both directions: accept/decline/tamper rejection.
- Mac pinned TLS gateway synthetic integration: occupancy, legacy and named requests, matching transcript, concurrent-request rejection, explicit approval, four-peer capacity and audio/microphone isolation.
- Shared Windows/Linux loopback TLS integration: read-only occupancy, real connected labels, malformed-name rejection, four-peer fanout, fifth-peer rejection, output/pause/control isolation and capture lifecycle.

## Still requires physical acceptance

Two phones on the same LAN: receiver stays on Connect or Settings, host invites; guest page identifies its role; leave and rejoin; tap an occupied PC; simultaneous Mac pairing requests. Verify early/late changes on actual Ubuntu output and acoustic two-phone alignment. No claim of acoustic sync or real-device UI acceptance from synthetic tests. Older installed apps need updating for the new occupancy/name protocol. Windows/Linux pairing remains QR-based; the named approval prompt exists on Mac.

Report quota is the preceding local commit `a987a70`; reporting service is live, mobile release pending. Do not overwrite the owner's installed apps or launch iOS audio simulator. Publish a new versioned desktop/mobile release and hosted privacy together when shipping this candidate; never replace already-published Preview23 assets.
