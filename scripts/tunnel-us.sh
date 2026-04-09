#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=geoshift-paths.sh
source "$SCRIPT_DIR/geoshift-paths.sh"

ENV_FILE="$(geoshift_default_env_file)"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "geoshift: missing or unreadable $ENV_FILE (set GEOSHIFT_ENV_FILE or create the file)" >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

: "${US_LIGHTSAIL_IP:?US_LIGHTSAIL_IP not set in $ENV_FILE}"
: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY not set in $ENV_FILE}"
: "${SSH_USER:=ubuntu}"

# sync rules before connecting (non-fatal: cached rules used if download fails)
/usr/local/lib/geoshift/geoshift-sync.sh || \
  echo "geoshift: rule sync failed, starting with cached rules" >&2

exec /usr/bin/autossh -M 0 -N -D 1080 \
  -i "$SSH_PRIVATE_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "${SSH_USER}@${US_LIGHTSAIL_IP}"
