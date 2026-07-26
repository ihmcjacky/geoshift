#!/usr/bin/env bash
# Fetch latest rule files from GitHub and write them to GEOSHIFT_CONFIG_DIR/rules/.
# Non-fatal: if a download fails the cached version is kept and a warning is printed.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/ihmcjacky/geoshift/master"

# config.yaml fetched to CONFIG_DIR root (not rules/)
CONFIG_FILES=(
  "config/config.yaml"
)

RULE_FILES=(
  "config/rules/jp-strict.yaml"
  "config/rules/jp-strict.txt"
  "config/rules/jp-content.yaml"
  "config/rules/jp-content.txt"
  "config/rules/us-ai.yaml"
  "config/rules/us-ai.txt"
)

ENV_FILE="${GEOSHIFT_ENV_FILE:-/etc/geoshift/geoshift.env}"
if [[ -r "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$ENV_FILE"; set +a
fi

CONFIG_DIR="${GEOSHIFT_CONFIG_DIR:-}"
if [[ -z "$CONFIG_DIR" ]]; then
  echo "geoshift-sync: GEOSHIFT_CONFIG_DIR not set in $ENV_FILE" >&2
  exit 1
fi

RULES_DIR="$CONFIG_DIR/rules"
if [[ ! -d "$RULES_DIR" ]]; then
  echo "geoshift-sync: rules directory not found: $RULES_DIR" >&2
  exit 1
fi

echo "geoshift-sync: fetching config and rules from GitHub..."
any_failed=0

for cfg_path in "${CONFIG_FILES[@]}"; do
  filename="$(basename "$cfg_path")"
  url="$REPO_RAW/$cfg_path"
  tmp="$(mktemp)"
  if curl -sfL --max-time 15 "$url" -o "$tmp"; then
    mv "$tmp" "$CONFIG_DIR/$filename"
    echo "  updated: $filename"
  else
    rm -f "$tmp"
    echo "  warning: failed to fetch $filename (keeping cached version)" >&2
    any_failed=1
  fi
done

for rule_path in "${RULE_FILES[@]}"; do
  filename="$(basename "$rule_path")"
  url="$REPO_RAW/$rule_path"
  tmp="$(mktemp)"
  if curl -sfL --max-time 15 "$url" -o "$tmp"; then
    mv "$tmp" "$RULES_DIR/$filename"
    echo "  updated: $filename"
  else
    rm -f "$tmp"
    echo "  warning: failed to fetch $filename (keeping cached version)" >&2
    any_failed=1
  fi
done

if [[ $any_failed -eq 0 ]]; then
  echo "geoshift-sync: all files up to date"
else
  echo "geoshift-sync: completed with warnings - some files may be stale" >&2
fi

# Re-apply local NordVPN settings from geoshift.env.
# geoshift sync overwrites config.yaml with the credential-free repo copy;
# this restores credentials and JP-STRICT order so they are never lost after a sync.
WIZARD_LIB="/usr/local/lib/geoshift/geoshift-config.sh"
CFG_YAML="$CONFIG_DIR/config.yaml"
if [[ -f "$WIZARD_LIB" && -f "$CFG_YAML" ]]; then
  echo "geoshift-sync: re-applying NordVPN settings from $ENV_FILE..."
  # Source only the set_nordvpn_config function; guard skips the interactive menu.
  _SOURCED_FOR_SYNC=1 source "$WIZARD_LIB" 2>/dev/null || true
  unset _SOURCED_FOR_SYNC
  set_nordvpn_config "$CFG_YAML"
  if /usr/local/bin/mihomo -t -d "$CONFIG_DIR" > /dev/null 2>&1; then
    echo "geoshift-sync: config validated OK"
  else
    echo "geoshift-sync: WARNING: mihomo -t failed after sync" >&2
    /usr/local/bin/mihomo -t -d "$CONFIG_DIR" || true
  fi
else
  echo "geoshift-sync: skipping NordVPN re-apply (wizard or config not found)" >&2
fi
