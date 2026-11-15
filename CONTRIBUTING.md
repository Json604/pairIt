# Contributing to PairIt

Start with the [README](README.md) for platform requirements, architecture and build commands.
Use Android Preview/test ads and unsigned or locally signed Apple builds for development.
Official release scripts depend on maintainer-only signing credentials; do not request or
copy those credentials. Forks distributing binaries must use their own app IDs, signing
keys, ad configuration, update feeds and report service. Do not submit synthetic reports
to the production report service; use its local tests.

## Changes and checks

1. Open an issue describing the problem for substantial changes. For a small fix, a
   focused pull request with a reproduction is enough.
2. Keep changes scoped. Preserve the existing design language, pairing authentication,
   audio routing, explicit user Stop/Pause intent and platform compatibility.
3. Add a regression check for a behavioural bug when practical. Run affected builds and
   tests from the README. Protocol changes need both desktop and phone compatibility
   checks. Do not rewrite unrelated code or bump release counters for a normal PR.
4. Explain the problem, the resulting behaviour, and what you tested. Distinguish a build
   or synthetic test from physical-device testing. Note any platforms you could not test.

Do not commit `.env` files, pairing QR codes/tokens, private keys, provisioning profiles,
local logs, generated binaries or user data. Inspect `git diff --cached` before committing.
Generated iOS configuration comes from `scripts/generate-ios-project.py`; Android help
and listing configuration come from `scripts/prepare-play-content.py`.

## Issues and support

[Public app reports](https://github.com/Json604/pairIt-download/issues) remain in the
existing downloads repository, including reports sent by the phone apps. Include app
builds, OS/desktop/audio-server versions, output type, reproduction steps and expected
versus actual behaviour. Remove secrets and personal information first. Use source PRs
for code changes; link the original report rather than duplicating it.

Report vulnerabilities privately using [SECURITY.md](SECURITY.md). Be respectful and
specific in reviews; discuss the code and behaviour, not the person. Contributions to
original PairIt code are under the repository’s MIT license. Preserve third-party notices
and disclose the origin and license of added code or assets.
