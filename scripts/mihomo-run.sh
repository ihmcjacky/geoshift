#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${GEOSHIFT_ENV_FILE:-/etc/geoshift/geoshift.env}"
if [[ -r "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$ENV_FILE"
  set +a
fi

CONFIG_DIR="${GEOSHIFT_CONFIG_DIR:-/home/jackylam/Documents/gitproj/geoshift/config}"
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  echo "geoshift: no config at $CONFIG_DIR/config.yaml" >&2
  exit 1
fi

exec /usr/local/bin/mihomo -d "$CONFIG_DIR"
