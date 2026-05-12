#!/usr/bin/env bash
# GeoShift CLI. Usage: geoshift <command>
set -euo pipefail

GEOSHIFT_LIB="${GEOSHIFT_LIB:-/usr/local/lib/geoshift}"
MIHOMO_API="http://127.0.0.1:9090"

SERVICES=(geoshift-tunnel-us.service geoshift-tunnel-jp.service geoshift-mihomo.service)

usage() {
  echo "Usage: geoshift <command>"
  echo ""
  echo "Commands (no elevated privileges required unless noted):"
  echo "  sync     Fetch latest config and rules from GitHub, write to config dir"
  echo "  reload   Reload Mihomo config via REST API (no restart needed)"
  echo "  status   Show running/stopped state of all GeoShift systemd services"
  echo "  start    Start all GeoShift services in correct order  [requires sudo]"
  echo "  stop     Stop all GeoShift services                    [requires sudo]"
  echo "  restart  Stop then re-start all services in correct order  [requires sudo]"
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
  status)
    for svc in "${SERVICES[@]}"; do
      state=$(systemctl is-active "$svc" 2>/dev/null || true)
      printf "  %-40s %s\n" "$svc" "$state"
    done
    ;;
  stop)
    # Stop Mihomo first (it depends on tunnels), then tunnels
    echo "geoshift: stopping all services..."
    sudo systemctl stop geoshift-mihomo.service geoshift-tunnel-us.service geoshift-tunnel-jp.service
    echo "geoshift: all services stopped."
    ;;
  start)
    # Start tunnels first, then Mihomo after a short wait
    echo "geoshift: starting tunnel services..."
    sudo systemctl start geoshift-tunnel-us.service geoshift-tunnel-jp.service
    echo "  Waiting 5 s for tunnels to come up..."
    sleep 5
    echo "  Starting geoshift-mihomo.service..."
    sudo systemctl start geoshift-mihomo.service
    echo "geoshift: all services started."
    ;;
  restart)
    echo "geoshift: stopping all services..."
    sudo systemctl stop geoshift-mihomo.service geoshift-tunnel-us.service geoshift-tunnel-jp.service
    echo "  Starting tunnel services..."
    sudo systemctl start geoshift-tunnel-us.service geoshift-tunnel-jp.service
    echo "  Waiting 5 s for tunnels to come up..."
    sleep 5
    echo "  Starting geoshift-mihomo.service..."
    sudo systemctl start geoshift-mihomo.service
    echo "geoshift: all services restarted."
    ;;
  *)
    echo "geoshift: unknown command: $cmd" >&2
    usage
    ;;
esac
