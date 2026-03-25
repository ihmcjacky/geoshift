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

: "${US_LIGHTSAIL_IP:?US_LIGHTSAIL_IP not set in $ENV_FILE}"
: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY not set in $ENV_FILE}"
: "${SSH_USER:=ubuntu}"

exec /usr/bin/autossh -M 0 -N -D 1080 \
  -i "$SSH_PRIVATE_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "${SSH_USER}@${US_LIGHTSAIL_IP}"
