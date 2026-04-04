#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${GEOSHIFT_ENV_FILE:-/etc/geoshift/geoshift.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "geoshift: missing or unreadable $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

: "${JP_LIGHTSAIL_IP:?JP_LIGHTSAIL_IP not set in $ENV_FILE}"
: "${JP_SSH_PRIVATE_KEY:?JP_SSH_PRIVATE_KEY not set in $ENV_FILE}"
: "${SSH_USER:=ubuntu}"

# sync rules before connecting (non-fatal: cached rules used if download fails)
/usr/local/lib/geoshift/geoshift-sync.sh || \
  echo "geoshift: rule sync failed, starting with cached rules" >&2

exec /usr/bin/autossh -M 0 -N -D 1081 \
  -i "$JP_SSH_PRIVATE_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o AddressFamily=inet \
  -o TCPKeepAlive=yes \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=6 \
  "${SSH_USER}@${JP_LIGHTSAIL_IP}"
