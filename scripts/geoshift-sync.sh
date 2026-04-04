#!/usr/bin/env bash
# Fetch latest rule files from GitHub and write them to GEOSHIFT_CONFIG_DIR/rules/.
# Non-fatal: if a download fails the cached version is kept and a warning is printed.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/ihmcjacky/geoshift/master"
RULE_FILES=(
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

echo "geoshift-sync: fetching rules from GitHub..."
any_failed=0
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
  echo "geoshift-sync: all rules up to date"
else
  echo "geoshift-sync: completed with warnings — some files may be stale" >&2
fi
