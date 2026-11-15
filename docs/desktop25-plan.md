# Desktop follow-up — 2026-11-15

## Published baseline
Preview24 + phone33 published; all12 assets verified; all6 CI jobs passed. iOS33 uploaded; Android33 AAB prepared for owner submission. See preview24-publication.json.

## Published25 / phone34
- Owner says Ubuntu delay probably affects all audio, not only videos. Phone default was fixed320ms Reliable prefill; Mac also provides virtual-output video compensation. Linux capture already requests10ms with5ms process time and bounds stale capture. Windows100ms WASAPI allocation is not proof of100ms delivery latency; event capture already drains packets. No speculative OS buffer change.
- Enable existing adaptive arrival learning on Linux/Windows with speaker/wired outputs on both phones.64 packets establish jitter95, plus two packets and output lead;40..320ms cushion; unstable sessions fall back to320ms. Bluetooth/Mac/unknown peers preserve Reliable. Live Android route changes reset learning/policy. Group deadlines and manual correction remain bounded. This needs mobile34; a desktop-only update cannot remove receiver buffering. Physical/acoustic improvement is NOT yet measured.
- Desktop launch and daily automatic checks. Windows/Linux use prominent Update app/Later dialog and shared process-local dedup policy (no stacking, no same-build reminder inside24hours). Existing signed installation/relaunch path unchanged. Failure retries allowed after5minutes; no error popup automatically.
- Mac Sparkle owns launch/daily checks and update dialog. Explicit startup before opening menu,86400second schedule, no automatic download/install; respects saved Sparkle check preference. Existing manual action retained.

## Release sequence
Published25 with all six CI jobs passed, mobile34, signed installers and Apple-notarized Mac app; site42 and public feeds31e58c3 live. iOS34 uploaded, Android34 signed AAB prepared for owner. Owner must install25 before publishing test26, otherwise older clients may skip25 and invalidate the prompt test. Do not overwrite installed owner apps, use computer UI, or launch iOS audio simulator. Windows physical updater remains unverified; Mac/Linux owner confirmed previous in-app install/relaunch.

Owner confirmed Mac/Linux25 and phone34 submissions. Desktop26 published as requested; all6CI43665497572 passed, notarized Mac,10asset digests verified, public feed08d3c0d, website44. Await owner automatic-prompt/install and acoustic testing. See desktop26-publication.json.
