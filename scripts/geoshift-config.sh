#!/usr/bin/env bash
# GeoShift configuration wizard (Linux).
# Usage: geoshift config              (interactive menu)
#        geoshift-config.sh full      (run all sections in sequence, called by installer)
set -euo pipefail

ENV_FILE="${GEOSHIFT_ENV_FILE:-/etc/geoshift/geoshift.env}"
MIHOMO_BIN="/usr/local/bin/mihomo"

# ---- env helpers -------------------------------------------------------

read_env_var() {
    local key="$1" default="${2:-}"
    if [[ ! -f "$ENV_FILE" ]]; then echo "$default"; return; fi
    local val
    val="$(grep -E "^\s*${key}\s*=" "$ENV_FILE" 2>/dev/null | tail -1 | sed "s/^\s*${key}\s*=\s*//" | sed 's/^"//;s/"$//')"
    echo "${val:-$default}"
}

write_env_var() {
    local key="$1" value="$2"
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "$key=$value" | sudo tee "$ENV_FILE" > /dev/null
        sudo chmod 600 "$ENV_FILE"
        return
    fi
    if grep -qE "^\s*${key}\s*=" "$ENV_FILE" 2>/dev/null; then
        sudo sed -i "s|^\s*${key}\s*=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "$key=$value" | sudo tee -a "$ENV_FILE" > /dev/null
    fi
}

# ---- NordVPN apply routine (canonical) ---------------------------------
# Called by installer and geoshift-sync.sh as well.

set_nordvpn_config() {
    local cfg="$1"
    [[ -f "$cfg" ]] || { echo "  config.yaml not found at $cfg, skipping NordVPN apply" >&2; return; }

    local enabled user pass server port
    enabled="$(read_env_var NORDVPN_ENABLED false)"
    user="$(read_env_var    NORDVPN_SERVICE_USERNAME)"
    pass="$(read_env_var    NORDVPN_SERVICE_PASSWORD)"
    server="$(read_env_var  NORDVPN_PROXY_SERVER jp874.proxy.nordvpn.com)"
    port="$(read_env_var    NORDVPN_PROXY_PORT 89)"

    local creds_ok=false
    if [[ "$enabled" == "true" && -n "$user" && -n "$pass" \
          && "$user" != *"your-"* && "$user" != *"YOUR_NORDVPN"* \
          && "$pass" != *"your-"* && "$pass" != *"YOUR_NORDVPN"* ]]; then
        creds_ok=true
    fi

    local tmp
    tmp="$(mktemp)"
    cp "$cfg" "$tmp"

    if $creds_ok; then
        python3 - "$tmp" "$server" "$port" "$user" "$pass" <<'PY'
import sys, re
path, server, port, user, pw = sys.argv[1:6]
text = open(path, encoding='utf-8').read()

def replace_in_block(text, field, value):
    pattern = r'(- name: NordVPN-JP\n(?:.*\n)*?    ' + field + r':)\s*.+'
    return re.sub(pattern, r'\g<1> ' + value, text)

text = replace_in_block(text, 'server',   server)
text = replace_in_block(text, 'port',     port)
text = replace_in_block(text, 'username', '"' + user + '"')
text = replace_in_block(text, 'password', '"' + pw   + '"')

# Restore JP-STRICT order: NordVPN-JP first
text = re.sub(
    r'(  - name: JP-STRICT\n    type: select\n    proxies:\n)(?:      - [^\n]+\n)+',
    r'\g<1>      - NordVPN-JP\n      - JP-TUNNEL\n      - DIRECT\n',
    text)

open(path, 'w', encoding='utf-8').write(text)
PY
        echo "  NordVPN credentials injected; JP-STRICT prefers NordVPN-JP."
    else
        python3 - "$tmp" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path, encoding='utf-8').read()

# Demote JP-STRICT: JP-TUNNEL first, NordVPN-JP last
text = re.sub(
    r'(  - name: JP-STRICT\n    type: select\n    proxies:\n)(?:      - [^\n]+\n)+',
    r'\g<1>      - JP-TUNNEL\n      - NordVPN-JP\n      - DIRECT\n',
    text)

open(path, 'w', encoding='utf-8').write(text)
PY
        echo "  NordVPN disabled: JP-STRICT will use JP-TUNNEL first (best-effort)."
        echo "  NOTE: Abema and similar sites block datacenter IPs."
        echo "  To enable NordVPN later: geoshift config -> option 2"
    fi

    sudo mv "$tmp" "$cfg"
    sudo chown "$(whoami):$(whoami)" "$cfg" 2>/dev/null || true
}

# ---- custom rule file helper -------------------------------------------

ensure_custom_rule_file() {
    local path="$1" group="$2" category="$3"
    [[ -f "$path" ]] && return
    {
        echo "# GeoShift custom rules (user-managed). NOT overwritten by 'geoshift sync'."
        echo "# Routed to $group alongside repo-managed $category.yaml."
        echo "payload: []"
    } | sudo tee "$path" > /dev/null
    sudo chown "$(whoami):$(whoami)" "$path" 2>/dev/null || true
    echo "  Created $path"
}

count_rule_domains() {
    local path="$1"
    [[ -f "$path" ]] || { echo 0; return; }
    grep -cE '^\s*- (DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR)' "$path" || echo 0
}

add_custom_domains() {
    local path="$1" group="$2" category="$3"
    ensure_custom_rule_file "$path" "$group" "$category"

    echo ""
    echo "  Enter domains to add (one per line)."
    echo "  Plain domain (e.g. example.com) becomes DOMAIN-SUFFIX,example.com"
    echo "  Full rule (e.g. DOMAIN,api.example.com) is kept as-is."
    echo "  Press Enter on an empty line when done."
    echo ""

    local entries=()
    while true; do
        read -r -p "  Domain: " domain
        domain="${domain// /}"
        [[ -z "$domain" ]] && break
        if echo "$domain" | grep -qE '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR),'; then
            entries+=("  - $domain")
        else
            entries+=("  - DOMAIN-SUFFIX,$domain")
        fi
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  No domains added."
        return
    fi

    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
        echo "$line" >> "$tmp"
        if [[ "$line" =~ ^payload: ]]; then
            for entry in "${entries[@]}"; do
                echo "$entry" >> "$tmp"
            done
        fi
    done < "$path"
    sudo mv "$tmp" "$path"
    sudo chown "$(whoami):$(whoami)" "$path" 2>/dev/null || true
    echo "  Added ${#entries[@]} domain(s) to $path"
}

# ---- prompt helper -----------------------------------------------------

prompt_env_value() {
    local key="$1" description="$2" default="${3:-}" secret="${4:-}"
    local current display
    current="$(read_env_var "$key" "$default")"
    if [[ -n "$secret" && -n "$current" && "$current" != *"your-"* && "$current" != *"YOUR_"* ]]; then
        display="********"
    else
        display="$current"
    fi

    echo ""
    echo "  $description"
    [[ -n "$display" ]] && echo "  Current: $display"
    read -r -p "  Value (Enter to keep): " input
    input="${input// /}"
    if [[ -n "$input" ]]; then
        write_env_var "$key" "$input"
        echo "$input"
    else
        echo "$current"
    fi
}

# ---- validate config ---------------------------------------------------

validate_config() {
    local config_dir
    config_dir="$(read_env_var GEOSHIFT_CONFIG_DIR)"
    [[ -z "$config_dir" ]] && return
    [[ -f "$config_dir/config.yaml" ]] || return

    echo "  Validating config..."
    if "$MIHOMO_BIN" -t -d "$config_dir" > /dev/null 2>&1; then
        echo "  Config OK"
    else
        "$MIHOMO_BIN" -t -d "$config_dir" || true
        echo "  WARNING: mihomo -t failed. Fix config.yaml before starting services." >&2
    fi
}

# ---- wizard sections ---------------------------------------------------

section_server() {
    echo ""
    echo "--- Server & SSH Settings ---"

    prompt_env_value 'US_HOST'   'US exit node IPv4 address'        > /dev/null
    prompt_env_value 'SSH_USER'  'SSH username (default: ubuntu)'    'ubuntu' > /dev/null
    prompt_env_value 'US_SSH_KEY' 'Path to US SSH private key (.pem)' > /dev/null
    prompt_env_value 'JP_HOST'   'JP exit node IPv4 address'         > /dev/null
    prompt_env_value 'JP_SSH_KEY' 'Path to JP SSH private key (.pem)' > /dev/null

    validate_config
}

section_nordvpn() {
    echo ""
    echo "--- NordVPN Proxy Settings ---"
    echo ""
    echo "  JP-STRICT routing (Abema and similar sites) uses NordVPN as a residential"
    echo "  JP proxy to bypass datacenter IP blocks. This requires a NordVPN subscription"
    echo "  with service credentials (not your login password)."
    echo "  Get them at: nordaccount.com -> NordVPN -> Set up manually -> Service credentials"

    read -r -p "  Do you have a NordVPN subscription with service credentials? [y/N] " answer
    local config_dir cfg_yaml
    config_dir="$(read_env_var GEOSHIFT_CONFIG_DIR)"
    cfg_yaml="$config_dir/config.yaml"

    if echo "$answer" | grep -qiE '^y'; then
        write_env_var 'NORDVPN_ENABLED' 'true'
        prompt_env_value 'NORDVPN_PROXY_SERVER'    'NordVPN JP proxy hostname' 'jp874.proxy.nordvpn.com' > /dev/null
        prompt_env_value 'NORDVPN_PROXY_PORT'      'NordVPN proxy port'        '89'                     > /dev/null
        prompt_env_value 'NORDVPN_SERVICE_USERNAME' 'NordVPN service username'  ''    secret > /dev/null
        prompt_env_value 'NORDVPN_SERVICE_PASSWORD' 'NordVPN service password'  ''    secret > /dev/null
    else
        write_env_var 'NORDVPN_ENABLED' 'false'
        echo ""
        echo "  NordVPN disabled. JP-STRICT sites will use JP-TUNNEL (best-effort)."
        echo "  You can enable NordVPN later by running: geoshift config -> option 2"
    fi

    if [[ -n "$config_dir" && -f "$cfg_yaml" ]]; then
        echo ""
        echo "  Applying NordVPN settings to config.yaml..."
        set_nordvpn_config "$cfg_yaml"
        validate_config
    else
        echo "  Skipping config.yaml apply (GEOSHIFT_CONFIG_DIR not set or config.yaml missing)."
        echo "  Re-run install.sh or set GEOSHIFT_CONFIG_DIR in $ENV_FILE"
    fi
}

section_rules() {
    echo ""
    echo "--- Custom Domain Rules ---"

    local config_dir rules_dir
    config_dir="$(read_env_var GEOSHIFT_CONFIG_DIR)"
    if [[ -z "$config_dir" ]]; then
        echo "  GEOSHIFT_CONFIG_DIR not set in $ENV_FILE" >&2
        echo "  Run install.sh first, then use 'geoshift config'." >&2
        return
    fi

    rules_dir="$config_dir/rules"
    if [[ ! -d "$rules_dir" ]]; then
        echo "  Rules directory not found: $rules_dir" >&2
        return
    fi

    local -a names=('us-ai'       'jp-strict'            'jp-content')
    local -a groups=('US-PROXY'   'JP-STRICT'            'JP-PROXY')
    local -a labels=('US AI services' 'JP strict (Abema-class)' 'JP general content')

    for i in "${!names[@]}"; do
        local name="${names[$i]}" group="${groups[$i]}" label="${labels[$i]}"
        local default_file="$rules_dir/$name.yaml"
        local custom_file="$rules_dir/$name-custom.yaml"
        ensure_custom_rule_file "$custom_file" "$group" "$name"

        local def_count cust_count
        def_count="$(count_rule_domains "$default_file")"
        cust_count="$(count_rule_domains "$custom_file")"

        echo ""
        echo "  [$label]"
        echo "    Default rules : $def_count domains"
        echo "    Custom rules  : $cust_count domains"
        echo "    Options:"
        echo "      a) Quick-add domains"
        echo "      e) Open custom file in editor (\$EDITOR)"
        echo "      s) Skip this category"
        read -r -p "    Choice [a/e/s]: " choice
        case "${choice,,}" in
            a) add_custom_domains "$custom_file" "$group" "$name" ;;
            e)
                local editor="${EDITOR:-nano}"
                echo "  Opening $custom_file in $editor..."
                "$editor" "$custom_file" || true
                ;;
            *) echo "    Skipped." ;;
        esac
    done

    local ok=false
    while ! $ok; do
        echo ""
        echo "  Validating config..."
        if "$MIHOMO_BIN" -t -d "$config_dir" > /dev/null 2>&1; then
            echo "  Config OK"
            ok=true
        else
            "$MIHOMO_BIN" -t -d "$config_dir" || true
            echo "  mihomo -t failed. Fix your custom rule files and press Enter to retry (Ctrl-C to abort)."
            read -r || true
        fi
    done
}

offer_reload() {
    read -r -p "  Reload Mihomo now? [Y/n] " answer
    if ! echo "$answer" | grep -qiE '^n'; then
        if curl -sf -X PUT 'http://127.0.0.1:9090/configs?force=true' \
                -H 'Content-Type: application/json' -d '{}' > /dev/null 2>&1; then
            echo "  Reloaded."
        else
            echo "  Mihomo API not reachable (services may not be running)."
        fi
    fi
}

# ---- main --------------------------------------------------------------

# When sourced by geoshift-sync.sh for function access only, skip the menu.
[[ "${_SOURCED_FOR_SYNC:-}" == "1" ]] && return 0 2>/dev/null || true

mode="${1:-menu}"

if [[ "$mode" == "full" ]]; then
    echo ""
    echo "GeoShift Full Configuration Wizard"
    echo "==================================="
    section_server
    section_nordvpn
    section_rules
    echo ""
    offer_reload
    echo ""
    echo "Configuration complete."
    exit 0
fi

while true; do
    echo ""
    echo "GeoShift Configuration"
    echo "======================"
    echo "  1) Server & SSH settings"
    echo "  2) NordVPN proxy"
    echo "  3) Custom domain rules"
    echo "  4) Run full wizard (1 -> 2 -> 3)"
    echo "  5) Open geoshift.env in editor"
    echo "  6) Open config.yaml in editor"
    echo "  q) Quit"
    echo ""
    read -r -p "Choice: " choice

    case "$choice" in
        1) section_server;  echo ""; offer_reload ;;
        2) section_nordvpn; echo ""; offer_reload ;;
        3) section_rules;   echo ""; offer_reload ;;
        4)
            section_server
            section_nordvpn
            section_rules
            echo ""
            offer_reload
            ;;
        5)
            _menu_editor="${EDITOR:-nano}"
            echo "Opening $ENV_FILE in $_menu_editor..."
            "$_menu_editor" "$ENV_FILE" || true
            ;;
        6)
            _menu_config_dir="$(read_env_var GEOSHIFT_CONFIG_DIR)"
            _menu_cfg_path="$_menu_config_dir/config.yaml"
            if [[ -n "$_menu_config_dir" && -f "$_menu_cfg_path" ]]; then
                _menu_editor="${EDITOR:-nano}"
                echo "Opening $_menu_cfg_path in $_menu_editor..."
                "$_menu_editor" "$_menu_cfg_path" || true
            else
                echo "config.yaml not found. Set GEOSHIFT_CONFIG_DIR in $ENV_FILE first." >&2
            fi
            ;;
        q) exit 0 ;;
        *) echo "  Unknown option: $choice" ;;
    esac
done
