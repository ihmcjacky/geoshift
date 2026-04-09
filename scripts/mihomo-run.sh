#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=geoshift-paths.sh
source "$SCRIPT_DIR/geoshift-paths.sh"

ENV_FILE="$(geoshift_default_env_file)"
if [[ -r "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$ENV_FILE"
  set +a
fi

CONFIG_DIR="${GEOSHIFT_CONFIG_DIR:-}"

# Linux: preserve pre–macOS behavior when GEOSHIFT_CONFIG_DIR is unset but
# /etc/geoshift/geoshift.env is the usual symlink into the repo — use <repo>/config.
if [[ -z "$CONFIG_DIR" ]] && [[ "$(uname -s)" == Linux ]] && [[ -e "$ENV_FILE" ]]; then
  env_canon="$(readlink -f "$ENV_FILE" 2>/dev/null || true)"
  [[ -n "$env_canon" ]] || env_canon="$ENV_FILE"
  repo_root="$(cd "$(dirname "$env_canon")" && pwd)"
  if [[ -f "$repo_root/config/config.yaml" ]]; then
    CONFIG_DIR="$repo_root/config"
  fi
fi

if [[ -z "$CONFIG_DIR" ]] || [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  echo "geoshift: set GEOSHIFT_CONFIG_DIR in $ENV_FILE to the directory containing config.yaml" >&2
  exit 1
fi

MIHOMO="$(geoshift_mihomo_bin)"
if [[ -z "$MIHOMO" ]] || [[ ! -x "$MIHOMO" ]]; then
  echo "geoshift: mihomo not found (install to /usr/local/bin/mihomo or set MIHOMO_BIN)" >&2
  exit 1
fi

exec "$MIHOMO" -d "$CONFIG_DIR"
