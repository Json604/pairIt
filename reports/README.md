# PairIt public problem reports

The native app submits only after the user taps Submit report and sees that the
report is public. No GitHub account is required. The server creates an issue in
`Json604/pairIt-download`; no repository or API URL comes from the client.

Deploy this directory separately at `/opt/pairit-reports` on the shared VPS.
Create a mode600 `.env` with a fine-grained `GITHUB_REPORTS_TOKEN` restricted to
that repository (Issues: write) and random `REPORTS_IP_SALT`. Never put the token
in app code, app configuration, command arguments, logs or source control.
Create `data` owned by10001 with mode700; run `docker compose up -d --build`.
Expose only loopback8788; Caddy terminates HTTPS at reports.pairit.kartikey.xyz,
limits request size, and overwrites X-Real-IP with the TCP client address.

Abuse bounds: max24KB JSON, strict schema,3newreports/hour/IP,5/day/IP,50/day
across the service. IP addresses are HMAC-hashed in SQLite; raw report bodies
and raw addresses are not logged/stored. SQLite retains idempotency metadata
(id, digest, hashed IP, time, status, public issue URL). Published report text
is stored publicly by GitHub. Anonymous reporting is not strong user identity;
these bounds limit spam, but determined distributed abuse may exhaust the quota.

The app retries the same UUID and frozen payload. Confirmed submissions return
the same issue. Ambiguous upstream timeouts/crashes never blindly create again:
they reconcile against a unique issue-body marker, including closed issues.
Unresolved submissions stay pending; owner intervention may be needed if an
issue was deleted or moved outside the bounded recent-issue reconciliation scan.
No automatic background submission or raw log/screenshot upload occurs.

Run `python3 -m unittest discover -s reports -p 'test_*.py'` from repository root.
