#!/usr/bin/env bash
# GeoShift installer (Ubuntu). Run: bash scripts/install.sh
# Re-runs are safe. Steps needing root are invoked via sudo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOMO_INSTALL="/usr/local/bin/mihomo"

die() { echo "geoshift install: $*" >&2; exit 1; }

arch="$(uname -m)"
[[ "$arch" == x86_64 ]] || die "expected x86_64, got $arch"

command -v curl >/dev/null || die "install curl first"
command -v jq >/dev/null || die "install jq first (sudo apt install -y jq)"

echo "==> Installing autossh (sudo)"
sudo apt-get update -qq
sudo apt-get install -y autossh

echo "==> Downloading latest Mihomo (linux-amd64)"
asset="$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
  | jq -r '.assets[] | select(.name|test("^mihomo-linux-amd64-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$")) | .browser_download_url' | head -1)"
[[ -n "$asset" ]] || die "could not resolve Mihomo download URL"
tmp="$(mktemp)"
curl -sL "$asset" | gunzip -c >"$tmp"
sudo install -m 0755 "$tmp" "$MIHOMO_INSTALL"
rm -f "$tmp"

echo "==> setcap (TUN without root)"
sudo setcap cap_net_admin,cap_net_bind_service+ep "$MIHOMO_INSTALL"

echo "==> GeoShift lib + env symlink"
sudo install -d -m 0755 /usr/local/lib/geoshift
sudo install -m 0755 "$REPO_ROOT/scripts/tunnel-us.sh"     /usr/local/lib/geoshift/tunnel-us.sh
sudo install -m 0755 "$REPO_ROOT/scripts/tunnel-jp.sh"     /usr/local/lib/geoshift/tunnel-jp.sh
sudo install -m 0755 "$REPO_ROOT/scripts/mihomo-run.sh"    /usr/local/lib/geoshift/mihomo-run.sh
sudo install -m 0755 "$REPO_ROOT/scripts/geoshift-sync.sh" /usr/local/lib/geoshift/geoshift-sync.sh
sudo install -m 0755 "$REPO_ROOT/scripts/geoshift.sh"      /usr/local/bin/geoshift
sudo install -d -m 0755 /etc/geoshift
if [[ ! -e /etc/geoshift/geoshift.env ]]; then
  sudo ln -sf "$REPO_ROOT/geoshift.env" /etc/geoshift/geoshift.env
elif [[ "$(readlink -f /etc/geoshift/geoshift.env 2>/dev/null || true)" != "$(readlink -f "$REPO_ROOT/geoshift.env")" ]]; then
  echo "Note: /etc/geoshift/geoshift.env already exists; not overwriting. Point it at $REPO_ROOT/geoshift.env if needed."
fi

echo "==> Disable IPv6 (sysctl)"
sudo install -m 0644 "$REPO_ROOT/sysctl.d/99-geoshift-disable-ipv6.conf" /etc/sysctl.d/99-geoshift-disable-ipv6.conf
sudo sysctl --system >/dev/null || sudo sysctl -p /etc/sysctl.d/99-geoshift-disable-ipv6.conf

echo "==> systemd units"
sudo install -m 0644 "$REPO_ROOT/systemd/geoshift-tunnel-us.service" /etc/systemd/system/
sudo install -m 0644 "$REPO_ROOT/systemd/geoshift-tunnel-jp.service" /etc/systemd/system/
sudo install -m 0644 "$REPO_ROOT/systemd/geoshift-mihomo.service" /etc/systemd/system/
sudo systemctl daemon-reload

echo "==> Validate Mihomo config"
if ! "$MIHOMO_INSTALL" -t -d "$REPO_ROOT/config" >/dev/null; then
  "$MIHOMO_INSTALL" -t -d "$REPO_ROOT/config" || true
  die "mihomo -t failed"
fi

echo
echo "Done. Ensure $REPO_ROOT/geoshift.env contains GEOSHIFT_CONFIG_DIR=$REPO_ROOT/config"
echo "SSH key must be chmod 600."
echo
echo "Start stack:"
echo "  sudo systemctl enable --now geoshift-tunnel-us.service geoshift-tunnel-jp.service geoshift-mihomo.service"
echo "Stop TUN (back to normal routing):"
echo "  sudo systemctl stop geoshift-mihomo.service"
echo "  (optional) sudo systemctl stop geoshift-tunnel-us.service geoshift-tunnel-jp.service"
echo
echo "Rule sync commands (no tunnel restart needed):"
echo "  geoshift sync    # fetch latest rules from GitHub"
echo "  geoshift reload  # reload Mihomo config"
echo
echo "Upgrading an existing install: git pull && bash scripts/install.sh"
echo "  Then: sudo systemctl restart geoshift-tunnel-us.service geoshift-tunnel-jp.service geoshift-mihomo.service"
