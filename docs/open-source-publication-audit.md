# Open-source publication audit — 2026-11-15

Scope: three independent read-only agents reviewed security/history, licensing/docs,
and engineering/release readiness. Primary agent prepared the changes below.
Audited baseline: `fe2c1bc`. The owner subsequently authorized retaining history,
removing operational details from current files, pushing this preparation and making
the source repository public. No history rewrite, migration, server change or new
binary release is part of publication preparation.

## Findings and disposition

| Area | Finding | Disposition |
| --- | --- | --- |
| Credentials | Gitleaks8.30.1:77 reachable commits/~2.52MB, zero findings. Independent scan:1,054 unique historical blobs, no confirmed private keys/tokens. | No credential-driven history rewrite indicated. Detection is not proof that no secret can exist. |
| Private operations | `docs/payment-removal-inventory-2026-11-14.json` (introduced6b927bc) contains unnecessary deployment/provider/test-account details. | Current deployment/provider/test-account details removed. Owner chose to preserve history; older versions remain accessible in historical commits. |
| Author metadata | Personal email appears in Git author history and intentional support metadata. | Owner accepted retaining existing history. Future local commits use GitHub noreply email; intentional public support contacts and third-party notices remain. |
| Ignore rules | App Store Connect `.p8`, plain PEM and SSH private-key filenames were not excluded; none found tracked. | Exclusions added. Existing public keys remain in their tracked source/configuration. |
| Developer build | Default Android script failed on macOS Bash3.2 due to an empty array under `set -u`. | Fixed conditional invocation; regression verifies default and Preview arguments without real SDK/signing state. |
| Documentation | Preview13/Together instructions, quota disclosure and release-feed instructions were stale. | README corrected; release instructions separated into RELEASING.md; generated Android help corrected. Help changes apply to the next build, not already submitted35. |
| Community | Contribution/security/report-routing guidance and PR template missing. | CONTRIBUTING.md, SECURITY.md, PR template and issue routing added. No response SLA or bounty invented. |
| Licensing | Original source MIT; inspected font, driver and bundled dependency notices present. No concrete incompatible-license blocker identified in reviewed assets. | THIRD_PARTY_NOTICES.md added; proprietary Google SDK terms explicitly distinguished from MIT original source. This is an inventory review, not legal certification. |
| CI | Read-only token, SHA-pinned actions, no privileged PR workflow, redacted full-history scan; no release credentials required. | Preserve. Added Linux NuGet Dependabot coverage. |
| Repository rules | Protection/ruleset read APIs returned403 for current private-repo plan. | After authorized public transition, configure required CI checks, restrict bypasses and block force pushes/deletion. Not verified/enabled by this audit. |
| Fork services | Official reporting endpoints, updater URLs/trust keys and publisher configuration remain in source. | CONTRIBUTING explicitly requires fork-specific identities/keys/ads/feeds/report service. A dedicated safe fork/development switch is recommended before encouraging redistributed forks. |
| Dependency reproducibility | .NET/Swift locks exist; Android lacks dependency locking/checksum verification. Bit-for-bit releases unproven. | Removed inaccurate “reproducible” claim from build script; recommend Gradle locks/verification as follow-up. |
| Runtime acceptance | Windows and physical iPhone acceptance still pending; no every-device guarantee. | README retains limitation; no large refactor or new audio behaviour introduced during publication prep. |

## Repository strategy

Keep `Json604/pairIt-download` for installed-client update feeds, signed assets and existing
in-app reports. Do not rename, delete, merge or redirect it as part of opening source.
Keep `Json604/pairIt` as the source/contribution repository. Existing binary release tags,
feed allowlists, updater signing trust and application signing identities stay stable.

The owner chose to retain existing source history and publish the source repository.
Current operational inventories have been sanitized; Git history has not been rewritten.
Older operational details and commit-author metadata remain discoverable in previous
commits. Public support contacts and legally required third-party attribution are retained.
AGENTS.md is now a tracked contributor guide. Personal handoff notes and machine-specific
configuration are excluded from that public guide.

## Verification and limits

- Gitleaks binary digest verified; independent historical blob scan used redacted output.
- Default Android build failure reproduced before the fix, both branches pass afterward.
- Python script tests and generated-content checks run for this preparation; inspect
  the current working diff before committing. Publication follows the owner’s explicit instruction.
- No tests contacted the production report service or used real payment/signing credentials.
- Remote private PR discussions, arbitrary CI logs, ignored local artifacts and provider-side
  key revocation are outside the history scan. Check GitHub-visible metadata before switching.
- Do not describe successful automated tests as physical Windows/iPhone acceptance.
