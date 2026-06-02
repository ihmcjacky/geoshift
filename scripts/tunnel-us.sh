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

: "${US_HOST:?US_HOST not set in $ENV_FILE}"
: "${US_SSH_KEY:?US_SSH_KEY not set in $ENV_FILE}"
: "${SSH_USER:=ubuntu}"

# sync rules before connecting (non-fatal: cached rules used if download fails)
/usr/local/lib/geoshift/geoshift-sync.sh || \
  echo "geoshift: rule sync failed, starting with cached rules" >&2

exec /usr/bin/autossh -M 0 -N -D 1080 \
  -i "$US_SSH_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o AddressFamily=inet \
  -o TCPKeepAlive=yes \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=6 \
  "${SSH_USER}@${US_HOST}"
