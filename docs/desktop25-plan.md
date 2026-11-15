# Desktop follow-up — 2026-11-15

Owner confirmed in-app download/install/relaunch works on physical Mac and Linux. Windows real installation remains unverified.

Sequence requested:
1. COMPLETED: desktop24 + phone33 published, all12 GitHub assets verified, CI43663365180 all6 passed; iOS33 uploaded; signed Android33 AAB in artifacts/publish-24/google-play. Public feeds7826a33, website41 deployed and verified. Final Mac app notarized/stapled after reusing unchanged trusted driver installer; rejected initial export was never published.
2. Investigate Ubuntu latency and Windows equivalents. Both phones currently default to320ms Reliable prefill; Mac additionally reports video compensation through its virtual audio output. Windows/Linux do not implement equivalent system video compensation. Distinguish video lip-sync from raw output latency. Owner clarification pending. Linux capture already requests10ms, timestamps sample cadence and restarts stale capture. Windows loopback requests100ms and reads on events/20ms fallback. Do not fake timestamps or claim system-wide video sync by simply reducing queues.
3. Add automatic visible update prompt on each desktop launch and every24hours while continuously open. Use existing signed installation path; no automatic installation without pressing Update. Prevent simultaneous/repeated dialogs. Preserve manual Settings update action, graceful restart and saved data.
4. Publish prompt-enabled desktop25; wait for owner to install25 before publishing test26. Never make26 live early, because22/23/24 could skip25 and the requested new-prompt test would be invalid.

Keep the source in private Json604/pairIt; only binary assets and public feeds in Json604/pairIt-download. Never overwrite published assets or owner's installed apps. No iOS simulator runtime. No computer UI; terminal/API uploads only. Site source /Volumes/PairItSite17/site; site41 is live with24 and foreground discovery/privacy changes.
