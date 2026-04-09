#!/usr/bin/env bash
# GeoShift installer (macOS). Run: bash scripts/install-macos.sh [--install-daemon]
# Installs Mihomo + scripts under /usr/local, LaunchAgent (user) for autossh,
# and a LaunchDaemon (root) for Mihomo TUN — TUN on macOS requires root.
#
# Optional: --install-daemon  sudo-copies the Mihomo plist and bootstraps system launchd.

set -euo pipefail

die() { echo "geoshift install-macos: $*" >&2; exit 1; }

INSTALL_DAEMON=false
for arg in "$@"; do
  case "$arg" in
    --install-daemon) INSTALL_DAEMON=true ;;
    *) die "unknown option: $arg (use --install-daemon or no args)" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOMO_INSTALL="/usr/local/bin/mihomo"
GEOSHIFT_ENV_FILE="${HOME}/.config/geoshift/geoshift.env"
LAUNCH_AGENT_DST="${HOME}/Library/LaunchAgents/io.geoshift.tunnel-us.plist"
LAUNCH_DAEMON_SRC="/tmp/io.geoshift.mihomo.plist.$$"
LAUNCH_DAEMON_DST="/Library/LaunchDaemons/io.geoshift.mihomo.plist"

[[ "$(uname -s)" == Darwin ]] || die "this script is for macOS only (use scripts/install.sh on Linux)"

arch="$(uname -m)"
case "$arch" in
  arm64)  mihomo_re='^mihomo-darwin-arm64-v[0-9]+\.[0-9]+\.[0-9]+\.gz$' ;;
  x86_64) mihomo_re='^mihomo-darwin-amd64-v[0-9]+\.[0-9]+\.[0-9]+\.gz$' ;;
  *) die "unsupported arch: $arch (expected arm64 or x86_64)" ;;
esac

command -v curl >/dev/null || die "install curl (xcode-select --install or brew install curl)"
command -v jq >/dev/null || die "install jq (brew install jq)"

if ! command -v autossh >/dev/null; then
  if command -v brew >/dev/null; then
    echo "==> Installing autossh via Homebrew"
    brew install autossh
  else
    die "autossh not found; install Homebrew (https://brew.sh) and run: brew install autossh"
  fi
fi

echo "==> Downloading latest Mihomo (darwin)"
asset="$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
  | jq -r --arg re "$mihomo_re" '.assets[] | select(.name|test($re)) | .browser_download_url' | head -1)"
[[ -n "$asset" ]] || die "could not resolve Mihomo download URL for $arch"
tmp="$(mktemp)"
curl -sL "$asset" | gunzip -c >"$tmp"
echo "==> Installing Mihomo to $MIHOMO_INSTALL (sudo)"
sudo install -m 0755 "$tmp" "$MIHOMO_INSTALL"
rm -f "$tmp"

echo "==> GeoShift scripts under /usr/local/lib/geoshift (sudo)"
sudo install -d -m 0755 /usr/local/lib/geoshift
sudo install -m 0755 "$REPO_ROOT/scripts/geoshift-paths.sh" /usr/local/lib/geoshift/geoshift-paths.sh
sudo install -m 0755 "$REPO_ROOT/scripts/tunnel-us.sh" /usr/local/lib/geoshift/tunnel-us.sh
sudo install -m 0755 "$REPO_ROOT/scripts/mihomo-run.sh" /usr/local/lib/geoshift/mihomo-run.sh

echo "==> User env: $GEOSHIFT_ENV_FILE"
install -d -m 0755 "${HOME}/.config/geoshift"
install -d -m 0755 "${HOME}/Library/Logs/geoshift"
if [[ ! -f "$GEOSHIFT_ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == GEOSHIFT_CONFIG_DIR=* ]]; then
      printf 'GEOSHIFT_CONFIG_DIR=%s\n' "$REPO_ROOT/config"
    else
      printf '%s\n' "$line"
    fi
  done <"$REPO_ROOT/geoshift.env.example" >"$GEOSHIFT_ENV_FILE"
  echo "Created $GEOSHIFT_ENV_FILE — edit US_LIGHTSAIL_IP, SSH_PRIVATE_KEY, GEOSHIFT_CONFIG_DIR"
else
  echo "Keeping existing $GEOSHIFT_ENV_FILE"
fi

escape_sed() { printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'; }
ef_esc="$(escape_sed "$GEOSHIFT_ENV_FILE")"
home_esc="$(escape_sed "$HOME")"

sed -e "s|@@GEOSHIFT_ENV_FILE@@|$ef_esc|g" -e "s|@@HOME@@|$home_esc|g" \
  "$REPO_ROOT/launchd/io.geoshift.tunnel-us.plist.in" >"$LAUNCH_AGENT_DST"
chmod 0644 "$LAUNCH_AGENT_DST"
echo "==> Wrote LaunchAgent: $LAUNCH_AGENT_DST"

sed -e "s|@@GEOSHIFT_ENV_FILE@@|$ef_esc|g" \
  "$REPO_ROOT/launchd/io.geoshift.mihomo.plist.in" >"$LAUNCH_DAEMON_SRC"

echo "==> Validate Mihomo config"
if ! "$MIHOMO_INSTALL" -t -d "$REPO_ROOT/config" >/dev/null; then
  "$MIHOMO_INSTALL" -t -d "$REPO_ROOT/config" || true
  die "mihomo -t failed"
fi

echo "==> Log directory for LaunchDaemon (sudo)"
sudo install -d -m 0755 /var/log/geoshift

if [[ "$INSTALL_DAEMON" == true ]]; then
  echo "==> Installing LaunchDaemon (sudo)"
  sudo install -m 0644 "$LAUNCH_DAEMON_SRC" "$LAUNCH_DAEMON_DST"
  sudo launchctl bootout system/io.geoshift.mihomo 2>/dev/null || true
  sudo launchctl bootstrap system "$LAUNCH_DAEMON_DST"
  rm -f "$LAUNCH_DAEMON_SRC"
  LAUNCH_DAEMON_SRC_NOTE="(installed to $LAUNCH_DAEMON_DST)"
else
  LAUNCH_DAEMON_SRC_NOTE="sudo install -m 0644 $LAUNCH_DAEMON_SRC $LAUNCH_DAEMON_DST"
fi

echo
echo "Done."
echo
echo "1) Edit $GEOSHIFT_ENV_FILE (SSH key chmod 600). Ensure GEOSHIFT_CONFIG_DIR points at your config folder."
if [[ "$INSTALL_DAEMON" == true ]]; then
  echo "2) LaunchDaemon: installed. Mihomo runs as root (required for TUN on macOS)."
else
  echo "2) Install LaunchDaemon (Mihomo as root — required for TUN on macOS):"
  echo "     $LAUNCH_DAEMON_SRC_NOTE"
  echo "     sudo launchctl bootout system/io.geoshift.mihomo 2>/dev/null || true"
  echo "     sudo launchctl bootstrap system $LAUNCH_DAEMON_DST"
  echo "   Or re-run: bash scripts/install-macos.sh --install-daemon"
fi
echo "3) Load the autossh LaunchAgent (runs as you, at login):"
echo "     launchctl bootstrap gui/\$(id -u) $LAUNCH_AGENT_DST"
echo "   Or log out and back in (RunAtLoad)."
echo
echo "Unload / stop:"
echo "  launchctl bootout gui/\$(id -u)/io.geoshift.tunnel-us"
echo "  sudo launchctl bootout system/io.geoshift.mihomo"
echo
if [[ "$INSTALL_DAEMON" != true ]]; then
  echo "Temp Mihomo plist (keep until installed): $LAUNCH_DAEMON_SRC"
  echo
fi
