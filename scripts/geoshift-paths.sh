#!/usr/bin/env bash
# Shared defaults for GeoShift shell scripts (sourced, not executed).
# shellcheck shell=bash

geoshift_default_env_file() {
  if [[ -n "${GEOSHIFT_ENV_FILE:-}" ]]; then
    printf '%s' "$GEOSHIFT_ENV_FILE"
    return
  fi
  case "$(uname -s)" in
    Darwin) printf '%s' "${HOME}/.config/geoshift/geoshift.env" ;;
    *)      printf '%s' "/etc/geoshift/geoshift.env" ;;
  esac
}

geoshift_mihomo_bin() {
  if [[ -n "${MIHOMO_BIN:-}" ]]; then
    printf '%s' "$MIHOMO_BIN"
    return
  fi
  if [[ -x /usr/local/bin/mihomo ]]; then
    printf '%s' "/usr/local/bin/mihomo"
    return
  fi
  local p
  p="$(command -v mihomo 2>/dev/null || true)"
  [[ -n "$p" ]] && printf '%s' "$p"
}
