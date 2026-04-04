#!/usr/bin/env bash
# GeoShift CLI. Usage: geoshift <command>
set -euo pipefail

GEOSHIFT_LIB="${GEOSHIFT_LIB:-/usr/local/lib/geoshift}"
MIHOMO_API="http://127.0.0.1:9090"

usage() {
  echo "Usage: geoshift <command>"
  echo "  sync    fetch latest rules from GitHub"
  echo "  reload  reload Mihomo config (via API, or restart service if API unreachable)"
  exit 1
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage

case "$cmd" in
  sync)
    exec "$GEOSHIFT_LIB/geoshift-sync.sh"
    ;;
  reload)
    echo "geoshift: reloading Mihomo config..."
    if curl -sf -X PUT "$MIHOMO_API/configs?force=true" \
        -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
      echo "geoshift: reloaded via API"
    else
      echo "geoshift: API not reachable, restarting systemd service..."
      sudo systemctl restart geoshift-mihomo.service
    fi
    ;;
  *)
    echo "geoshift: unknown command: $cmd" >&2
    usage
    ;;
esac
