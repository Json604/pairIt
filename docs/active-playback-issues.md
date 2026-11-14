# Playback and Listen Together fixes — 2026-11-15

User reports from physical Ubuntu testing of Preview19. Keep each issue open until its stated verification is complete; distinguish automated evidence from physical acceptance.

| ID | Report / requested behavior | Owner | Status | Acceptance checks |
| --- | --- | --- | --- | --- |
| 1 | Ubuntu has more latency than Mac with the same phone | linux_latency_round2 | Implemented; PulseAudio/PipeWire checks passed; physical latency comparison pending | Capture buffering/timestamps measured; audio regression passes; same-phone physical comparison still needed |
| 2 | Changing video/audio sync disconnects | mobile_sync_round2 | Implemented; regression checks passed; physical acceptance pending | Change/reset correction during playback keeps authenticated connection and playback intent on Android/iOS |
| 3 | Two phones audibly out of sync | mobile_sync_round2 | Implemented; regression checks passed; physical acceptance pending | Shared timeline/scheduling and per-output latency checked; two-phone acoustic test still needed |
| 4 | “When more than one phone connects to the same laptop…” | group_rules_round2 | Implemented; four/fifth-phone and independent-pause protocol checks passed | Up to four phones connect; fifth sees group full; each listener keeps own volume and pause |
| 5 | Missing host/invitee messages and Listen Together output rules | group_rules_round2 | Implemented; invitation and readiness checks passed; UI/device check pending | Explicit host/guest roles, accept/decline/busy/timeout, host readiness and limit enforcement; no silent output fallback |
| 6 | Refresh and audio/video sync on main Connect page | root | Implemented; Android/iOS builds passed; visual/device check pending | Direct discover refresh and playback refresh/sync controls on Android/iOS; usable enabled states; consistent app styling |

## Constraints
- Free with ads, up to four phones; no payments.
- Preserve normal explicit Connect through phone speaker or connected headphones.
- No unattended iOS simulator or physical Mac audio playback.
- No store submission or claim of acoustic verification from automated tests alone.
- User uploaded Android31 and submitted iOS31. These new fixes are separate from those builds.

## Evidence / decisions
- User clarified item4: multiple phones should connect to the same laptop (up to four). Item5 means neither phone has a laptop connection; phone speakers are valid outputs. Guest needs no prior laptop pairing when accepting a ready host.
- Initial inspection: Android sync adjustment/reset explicitly calls `RelayService.stopFromUi`, explaining the reported disconnect. Replace with in-session adjustment.
- Two-phone offset was heard through both phones’ built-in speakers, small but audible at close range. No phone models supplied.
- Ubuntu capture baseline delivered 149/298 intervals under 2 ms (paired 10 ms packets); 10 ms capture / 5 ms processing request eliminated these bursts in the isolated PulseAudio measurement. Hardware latency remains separate.

## Physical acceptance pass (after installing the candidate on computer and phones)
1. Same Ubuntu computer + same phone/output: compare normal audio latency and video lip sync separately against Mac. Record output type and whether the video player was restarted. Linux does not have the Mac driver’s video compensation.
2. While playing, tap sync correction in both directions and reset it. The connection and listening intent must survive. Pause first and repeat: correction must not start audio.
3. Play a repeating click track through two phones’ speakers. Compare at equal distance from both speakers, then repeat after late join, pause/resume and several minutes. Record physical offset; passing scheduling tests alone is insufficient.
4. Connect phones independently as well as through invitations. Up to four work; pausing one must leave the other playing. A fifth receives a clear full-group message.
5. Open Together with neither phone connected to a computer: show an actionable prerequisite. Connect only the host; an unpaired guest can receive a clearly labeled invitation, compare codes, accept or decline. Test host disconnecting while approval is pending.
6. Main Connect screen exposes refresh and sync directly. Discovery refresh must not erase saved pairing; playback refresh must not change the chosen output or restart paused audio. Check small screens and larger text.

## Candidate verification
- [x] Android build 32 compiles; lint passes. Preview APK is a separate app with test ads.
- [x] iOS build 32 simulator target compiles; simulator app was not launched.
- [x] Mac universal build20, Windows x64 build20, Linux x64/ARM64 preview20 compiled; ARM64 .deb upgrade19→20 and installed startup passed. Mac candidate is locally ad-hoc signed, not notarized for distribution.
- [x] Windows shared-protocol tests cover mixed-version timing, late join, output relearning, last-listener departure, four/fifth receiver admission, and independent pause.
- [x] Mac raw server and real TLS gateway tests cover bounded group timing and full-group delivery; invalid authentication receives no group information.
- [x] iOS transport regression receives full-group once without retrying.
- [x] Linux PulseAudio/PipeWire preserve 10 ms sample spacing and recover from a deliberate 350 ms capture stall while retaining the private route.
- [x] Shared-start timing rejects late startup more tightly while preserving solo behavior and cancellation when paused.
- [ ] Physical two-speaker timing / Ubuntu versus Mac latency comparison.
- [ ] Phone visual check at small screen/larger text; confirm refresh and sync controls and invitation wording.

Test logs: `artifacts/playback-round2/`, `artifacts/audio-round2/`, and `artifacts/linux-latency-round2/`. These are local test candidates; public feed remains Preview19 and store builds remain31. No store submission performed for this round.

Video correction is Mac-only: Linux/Windows lack system video compensation. Their ineffective correction controls are now disabled with an explanation; shared-phone presentation timing works separately. This limitation must not be described as fixed video lip sync on every OS.
