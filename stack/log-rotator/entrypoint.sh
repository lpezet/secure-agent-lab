#!/bin/sh
# Runs as root (unlike broker/proxy/cred-gateway) specifically so it can fix
# up permissions on the shared audit-logs volume and copytruncate files
# regardless of which non-root uid (broker's `node`, proxy's `mitmproxy`)
# wrote them. Re-applied on every start, not just first creation, so a
# volume that ended up owned by whichever service happened to mount it
# first gets corrected instead of leaving writers silently failing.
set -e

mkdir -p /var/log/audit
chmod 1777 /var/log/audit

exec crond -f -l 8
