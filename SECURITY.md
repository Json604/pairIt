# Security policy

## Report privately

Email **kartikey060105@gmail.com** with the subject “PairIt security report”. Do not
use the in-app report form or public GitHub issues for vulnerabilities, credentials,
pairing codes or private user data. Include affected versions, impact, reproduction
steps and a minimal proof of concept without targeting other people’s devices.

Reports are reviewed by the maintainer on a best-effort basis. This project does not
promise a response SLA or a paid bounty. Please allow time for assessment and a fix
before publishing exploit details.

## Supported versions and scope

Security fixes target the latest source and current platform release. There is no
commitment to backport to older previews. Published platform build numbers can differ;
consult the release notes. Preview status and incomplete hardware testing are documented
in the README.

Pairing credentials and certificate verification protect local audio connections.
Discovery is not authentication. Pairing QR links contain credentials; do not share
screenshots publicly. Forgetting a phone’s saved computer does not revoke copied
credentials on other devices. Stop sharing if a code is exposed and report it privately.

Review source, use isolated/local fixtures and test only systems you own or have permission
to test. Do not load-test the public reporting service or use it for automated test issues.
