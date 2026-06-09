#!/usr/bin/env bash
# ==============================================================================
# JumpServerCE Installer
# Target:   Ubuntu 24.04 LTS
# Features: FQDN verification, Let's Encrypt TLS, nginx reverse proxy,
#           fail2ban (SSH:22, Koko:2222, web), ufw firewall, idempotency
#
# Usage:
#   sudo bash install.sh [--force-hardware] [--fqdn <domain>] [--email <addr>]
#
# Flags:
#   --force-hardware   Skip CPU/RAM minimum checks
#   --fqdn <domain>    Pre-supply FQDN (skips interactive prompt)
#   --email <addr>     Let's Encrypt notification email (skips prompt)
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/jumpserver-install.log"
readonly JUMPSERVER_DIR="/opt/jumpserver"
readonly JUMPSERVER_HTTP_PORT=8080
readonly NGINX_CONF="/etc/nginx/sites-available/jumpserver.conf"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/jumpserver.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/jumpserver.conf"
readonly FAIL2BAN_FILTER="/etc/fail2ban/filter.d/jumpserver-web.conf"
readonly RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"
readonly MIN_CPU=4
readonly MIN_RAM_KB=$(( 8 * 1024 * 1024 ))   # 8 GB in kB

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Global state ─────────────────────────────────────────────────────────────
FORCE_HARDWARE=false
FQDN=""
LE_EMAIL=""

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }
die()     { error "$*"; exit 1; }

header() {
    echo -e "\n${BOLD}${CYAN}────────────────────────────────────────────────────${NC}" | tee -a "$LOG_FILE"
    echo -e   "${BOLD}${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e   "${BOLD}${CYAN}────────────────────────────────────────────────────${NC}\n" | tee -a "$LOG_FILE"
}

# ── Error trap ────────────────────────────────────────────────────────────────
on_exit() {
    local code=$?
    [[ $code -eq 0 ]] && return
    error "Script exited unexpectedly (code $code). See: $LOG_FILE"
}
trap on_exit EXIT

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-hardware) FORCE_HARDWARE=true ;;
            --fqdn)           FQDN="${2:?'--fqdn requires a value'}"; shift ;;
            --email)          LE_EMAIL="${2:?'--email requires a value'}"; shift ;;
            --help|-h)
                echo "Usage: sudo bash $0 [--force-hardware] [--fqdn <domain>] [--email <addr>]"
                exit 0
                ;;
            *) die "Unknown argument: $1. Try --help." ;;
        esac
        shift
    done
}

# ── Utilities ─────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root: sudo bash $0"
}

port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${1} "
}

get_server_public_ip() {
    curl -s --max-time 10 https://ifconfig.me 2>/dev/null   || \
    curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 10 https://icanhazip.com 2>/dev/null || \
    die "Cannot determine public IP. Check internet connectivity."
}

jumpserver_installed() {
    # Check stable path first, then versioned installer dirs (e.g. /opt/jumpserver-installer-v4.x.x)
    [[ -f "$JUMPSERVER_DIR/jmsctl.sh" ]] && return 0
    local versioned
    versioned=$(find /opt -maxdepth 1 -name "jumpserver-installer-*" -type d 2>/dev/null | head -1)
    [[ -n "$versioned" && -f "$versioned/jmsctl.sh" ]]
}

# Returns the actual JumpServer directory (stable symlink or versioned path)
get_js_dir() {
    [[ -f "$JUMPSERVER_DIR/jmsctl.sh" ]] && echo "$JUMPSERVER_DIR" && return
    find /opt -maxdepth 1 -name "jumpserver-installer-*" -type d 2>/dev/null | \
        while read -r d; do [[ -f "$d/jmsctl.sh" ]] && echo "$d" && return; done
}

read_fqdn_from_nginx() {
    [[ -f "$NGINX_CONF" ]] && \
        grep -m1 "server_name" "$NGINX_CONF" | awk '{print $2}' | tr -d ';' || true
}

# ── Idempotency: existing install ─────────────────────────────────────────────
handle_existing_install() {
    header "Existing Installation Detected"

    local existing_fqdn
    existing_fqdn=$(read_fqdn_from_nginx)

    [[ -n "$existing_fqdn" ]] && echo -e "  Existing FQDN: ${BOLD}$existing_fqdn${NC}"
    echo -e   "  JumpServer:    ${BOLD}$JUMPSERVER_DIR${NC}"
    echo ""

    # Pre-populate global FQDN for use in do_uninstall (cert removal)
    [[ -z "$FQDN" && -n "$existing_fqdn" ]] && FQDN="$existing_fqdn"

    echo "What would you like to do?"
    echo "  [1] Reinstall  — remove everything, then fresh install"
    echo "  [2] Uninstall  — remove JumpServer, nginx config, fail2ban config"
    echo "  [3] Exit"
    echo ""

    local choice
    while true; do
        read -rp "Choice [1-3]: " choice
        case $choice in
            1) do_uninstall; break ;;   # continue into fresh install
            2) do_uninstall; exit 0 ;;
            3) log "Exiting."; exit 0 ;;
            *) warn "Enter 1, 2, or 3." ;;
        esac
    done
}

do_uninstall() {
    header "Uninstalling JumpServerCE"

    if jumpserver_installed; then
        log "Stopping JumpServer containers..."
        "$JUMPSERVER_DIR/jmsctl.sh" stop 2>/dev/null     || warn "jmsctl stop failed — continuing."
        log "Removing JumpServer containers and images..."
        "$JUMPSERVER_DIR/jmsctl.sh" uninstall 2>/dev/null || warn "jmsctl uninstall failed — continuing."
    fi

    if [[ -L "$NGINX_ENABLED" || -f "$NGINX_ENABLED" ]]; then
        log "Removing nginx site config..."
        rm -f "$NGINX_ENABLED" "$NGINX_CONF"
        systemctl is-active --quiet nginx && systemctl reload nginx 2>/dev/null || true
    fi

    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        log "Removing fail2ban config..."
        rm -f "$FAIL2BAN_JAIL" "$FAIL2BAN_FILTER"
        systemctl is-active --quiet fail2ban && systemctl reload fail2ban 2>/dev/null || true
    fi

    rm -f "$RENEWAL_HOOK"

    ok "Core components removed."

    # Optional: remove Let's Encrypt certificate
    if [[ -n "$FQDN" && -d "/etc/letsencrypt/live/$FQDN" ]]; then
        read -rp "Remove Let's Encrypt certificate for $FQDN? [y/N] " rm_cert
        if [[ "${rm_cert,,}" == "y" ]]; then
            certbot delete --cert-name "$FQDN" --non-interactive 2>/dev/null && \
                ok "Certificate removed." || \
                warn "certbot delete failed — remove manually: certbot delete --cert-name $FQDN"
        fi
    fi

    # Optional: remove JumpServer data directory
    if [[ -d "$JUMPSERVER_DIR" ]]; then
        read -rp "Remove JumpServer data directory ($JUMPSERVER_DIR)? [y/N] " rm_data
        if [[ "${rm_data,,}" == "y" ]]; then
            rm -rf "$JUMPSERVER_DIR"
            ok "Removed $JUMPSERVER_DIR"
        else
            warn "Data directory retained. A fresh install may conflict — remove manually if needed."
        fi
    fi

    ok "Uninstall complete."
}

# ── Phase 1: Pre-flight checks ────────────────────────────────────────────────
preflight_checks() {
    header "Phase 1: Pre-flight Checks"

    # OS check
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
            ok "OS: ${PRETTY_NAME:-Ubuntu 24.04}"
        else
            warn "Tested on Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}"
            read -rp "Continue on unsupported OS? [y/N] " cont
            [[ "${cont,,}" == "y" ]] || die "Aborted: unsupported OS."
        fi
    fi

    # Hardware checks — bypassable with --force-hardware
    if [[ "$FORCE_HARDWARE" == "true" ]]; then
        warn "Hardware requirement checks bypassed (--force-hardware)"
    else
        local cpus; cpus=$(nproc)
        if [[ $cpus -lt $MIN_CPU ]]; then
            die "Insufficient CPUs: $cpus detected, $MIN_CPU required. Use --force-hardware to bypass."
        fi
        ok "CPUs: $cpus (minimum $MIN_CPU)"

        local ram_kb; ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        local ram_gb=$(( ram_kb / 1024 / 1024 ))
        if [[ $ram_kb -lt $MIN_RAM_KB ]]; then
            die "Insufficient RAM: ${ram_gb}GB detected, 8GB required. Use --force-hardware to bypass."
        fi
        ok "RAM: ${ram_gb}GB (minimum 8GB)"
    fi

    # Internet connectivity
    log "Checking internet connectivity..."
    curl -s --max-time 10 https://github.com > /dev/null 2>&1 || \
        die "No internet access — cannot reach github.com."
    ok "Internet connectivity"

    # Stop managed services that may be running from a previous partial install.
    # nginx and fail2ban are owned entirely by this script — always safe to stop here.
    for svc in nginx fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping $svc from previous run..."
            systemctl stop "$svc" 2>/dev/null || true
        fi
    done

    # Stop any lingering JumpServer Docker containers (jms_*) from a previous partial install.
    # These hold ports 80 and 2222 via docker-proxy even when jmsctl.sh no longer exists.
    if command -v docker &>/dev/null; then
        local jms_containers
        jms_containers=$(docker ps -q --filter "name=jms_" 2>/dev/null) || true
        if [[ -n "$jms_containers" ]]; then
            log "Stopping and removing lingering JumpServer containers from previous run..."
            # shellcheck disable=SC2086
            docker stop $jms_containers 2>/dev/null || true
            # shellcheck disable=SC2086
            docker rm   $jms_containers 2>/dev/null || true
        fi
    fi

    # Required ports must be free before install begins
    # Note: port 80 is used transiently by certbot standalone, then by nginx
    for port in 80 443 2222 $JUMPSERVER_HTTP_PORT; do
        if port_in_use "$port"; then
            local owner; owner=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
            die "Port $port is already in use (${owner}). Free it and re-run."
        fi
        ok "Port $port: free"
    done
}

# ── Phase 2: FQDN collection and DNS verification ─────────────────────────────
collect_fqdn() {
    header "Phase 2: FQDN Verification"

    validate_fqdn_format() {
        [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
    }

    if [[ -z "$FQDN" ]]; then
        while true; do
            read -rp "FQDN for JumpServer (e.g. jump.example.com): " FQDN
            validate_fqdn_format "$FQDN" && break
            warn "Invalid FQDN format. Enter a valid fully-qualified domain name."
        done
    else
        validate_fqdn_format "$FQDN" || die "Invalid FQDN: $FQDN"
        log "Using FQDN: $FQDN"
    fi

    # Get this server's public IP
    log "Determining server public IP..."
    local server_ip; server_ip=$(get_server_public_ip)
    log "Server public IP: $server_ip"

    # Resolve FQDN (install dnsutils if needed)
    command -v dig &>/dev/null || { log "Installing dnsutils..."; apt-get install -y -qq dnsutils; }

    log "Resolving $FQDN..."
    local dns_ip
    dns_ip=$(dig +short "$FQDN" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1) || true

    if [[ -z "$dns_ip" ]]; then
        die "$FQDN has no DNS A record. Create one pointing to $server_ip, wait for propagation, then re-run."
    fi

    log "DNS resolution: $FQDN → $dns_ip"

    if [[ "$dns_ip" != "$server_ip" ]]; then
        error "DNS mismatch:"
        error "  $FQDN resolves to: $dns_ip"
        error "  This server is:    $server_ip"
        die "Update your DNS A record — $FQDN must point to $server_ip"
    fi

    ok "DNS verified: $FQDN → $server_ip"

    echo ""
    echo -e "  FQDN:      ${BOLD}$FQDN${NC}"
    echo -e "  Public IP: ${BOLD}$server_ip${NC}"
    echo ""
    read -rp "Proceed with this FQDN? [Y/n] " confirm_fqdn
    [[ "${confirm_fqdn,,}" != "n" ]] || die "Aborted by user."

    # Let's Encrypt notification email (optional)
    if [[ -z "$LE_EMAIL" ]]; then
        echo ""
        read -rp "Email for Let's Encrypt expiry notices (Enter to skip): " LE_EMAIL
    fi
}

# ── Phase 3: Package installation ────────────────────────────────────────────
install_packages() {
    header "Phase 3: Installing Packages"

    log "Updating apt package lists..."
    apt-get update -qq

    log "Installing: nginx, certbot, fail2ban, ufw, dnsutils..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        nginx \
        certbot \
        python3-certbot-nginx \
        fail2ban \
        ufw \
        dnsutils \
        curl \
        wget

    ok "Packages installed."
}

# ── Phase 4: Let's Encrypt certificate ───────────────────────────────────────
obtain_certificate() {
    header "Phase 4: Let's Encrypt Certificate"

    if [[ -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ]]; then
        warn "Certificate for $FQDN already exists — skipping issuance."
        ok "Using existing certificate: /etc/letsencrypt/live/$FQDN/"
        return 0
    fi

    # nginx may auto-start on package install; stop it so standalone certbot can bind port 80
    if systemctl is-active --quiet nginx; then
        log "Temporarily stopping nginx to free port 80..."
        systemctl stop nginx
    fi

    local certbot_args=(
        certonly
        --standalone
        --non-interactive
        --agree-tos
        -d "$FQDN"
        --cert-name "$FQDN"
    )

    if [[ -n "$LE_EMAIL" ]]; then
        certbot_args+=(--email "$LE_EMAIL")
    else
        certbot_args+=(--register-unsafely-without-email)
        warn "No email provided. You will not receive expiry notifications from Let's Encrypt."
    fi

    log "Requesting certificate for $FQDN (port 80 must be reachable from the internet)..."
    certbot "${certbot_args[@]}" || \
        die "certbot failed. Ensure port 80 is open and reachable from the internet, then re-run."

    ok "Certificate issued: /etc/letsencrypt/live/$FQDN/"

    # Deploy hook: reload nginx on every auto-renewal
    mkdir -p "$(dirname "$RENEWAL_HOOK")"
    cat > "$RENEWAL_HOOK" <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
    chmod +x "$RENEWAL_HOOK"
    ok "Cert renewal hook: $RENEWAL_HOOK"

    # Activate auto-renewal (Ubuntu apt certbot uses a cron job; systemd timer may also exist)
    systemctl enable --now certbot.timer 2>/dev/null && \
        ok "Certbot auto-renewal: systemd timer enabled." || \
        log "Auto-renewal via cron (/etc/cron.d/certbot)."
}

# ── Phase 5: nginx reverse proxy ─────────────────────────────────────────────
configure_nginx() {
    header "Phase 6: nginx Reverse Proxy"

    # Remove the default placeholder site
    rm -f /etc/nginx/sites-enabled/default

    # Note: uses 'listen 443 ssl http2' syntax for nginx 1.24.x (Ubuntu 24.04)
    cat > "$NGINX_CONF" <<NGINX_CONF
# JumpServerCE reverse proxy
# Managed by install.sh v${SCRIPT_VERSION} — do not edit manually

upstream jumpserver_backend {
    server 127.0.0.1:${JUMPSERVER_HTTP_PORT};
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${FQDN};

    ssl_certificate     /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;

    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    client_max_body_size 100m;

    access_log /var/log/nginx/jumpserver-access.log;
    error_log  /var/log/nginx/jumpserver-error.log;

    location / {
        proxy_pass         http://jumpserver_backend;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # WebSocket support — required for Luna (web terminal)
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";

        # Long timeouts for interactive terminal sessions
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_connect_timeout 60s;
    }
}
NGINX_CONF

    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"

    nginx -t || die "nginx configuration test failed. Check: $NGINX_CONF"

    # Safety net: if JumpServer's web container is still holding port 80 (e.g. port
    # reconfiguration was skipped because config.txt wasn't found), stop it now so
    # nginx can bind.
    if command -v docker &>/dev/null; then
        local web_ids
        web_ids=$(docker ps -q --filter "name=jms_web" 2>/dev/null) || true
        if [[ -n "$web_ids" ]]; then
            warn "jms_web container is still running — stopping it so nginx can own port 80..."
            # shellcheck disable=SC2086
            docker stop $web_ids 2>/dev/null || true
            sleep 2
        fi
    fi

    systemctl enable nginx
    systemctl start nginx || die "nginx failed to start. Run: journalctl -xeu nginx.service"
    systemctl reload nginx 2>/dev/null || true

    ok "nginx: https://$FQDN → 127.0.0.1:$JUMPSERVER_HTTP_PORT (TLS terminated at host)"
}

# ── Phase 6: JumpServerCE installation ───────────────────────────────────────
install_jumpserver() {
    header "Phase 5: JumpServerCE Installation"

    log "Downloading JumpServer quick_start.sh..."
    curl -sSL \
        https://github.com/jumpserver/jumpserver/releases/latest/download/quick_start.sh \
        -o /tmp/js_quick_start.sh

    log "Running JumpServer installer (Docker image pulls may take several minutes)..."
    bash /tmp/js_quick_start.sh || die "JumpServer installation script failed."
    rm -f /tmp/js_quick_start.sh

    # quick_start.sh installs to a versioned path (e.g. /opt/jumpserver-installer-v4.x.x).
    # Find it and create a stable symlink at $JUMPSERVER_DIR so the rest of the script works unchanged.
    local actual_dir
    actual_dir=$(find /opt -maxdepth 1 -name "jumpserver-installer-*" -type d 2>/dev/null | sort -V | tail -1)

    if [[ -z "$actual_dir" || ! -f "$actual_dir/jmsctl.sh" ]]; then
        die "jmsctl.sh not found after install. Installation may have failed. Check: $LOG_FILE"
    fi

    if [[ "$actual_dir" != "$JUMPSERVER_DIR" ]]; then
        log "Creating stable symlink: $JUMPSERVER_DIR → $actual_dir"
        if [[ -L "$JUMPSERVER_DIR" ]]; then
            rm -f "$JUMPSERVER_DIR"       # stale symlink
        elif [[ -d "$JUMPSERVER_DIR" ]]; then
            rm -rf "$JUMPSERVER_DIR"      # leftover directory from a previous partial install
        fi
        ln -s "$actual_dir" "$JUMPSERVER_DIR"
    fi

    # Reconfigure internal HTTP port from 80 → $JUMPSERVER_HTTP_PORT
    # so host nginx can own ports 80/443 without conflict.
    local config; config=$(find_js_config)

    if [[ -n "$config" ]]; then
        log "Reconfiguring JumpServer HTTP port: 80 → $JUMPSERVER_HTTP_PORT (config: $config)..."

        log "Stopping JumpServer containers..."
        "$JUMPSERVER_DIR/jmsctl.sh" stop 2>/dev/null || warn "jmsctl stop failed — continuing."

        if grep -q "^HTTP_PORT=" "$config"; then
            sed -i "s|^HTTP_PORT=.*|HTTP_PORT=${JUMPSERVER_HTTP_PORT}|" "$config"
        else
            echo "HTTP_PORT=${JUMPSERVER_HTTP_PORT}" >> "$config"
        fi

        # Disable JumpServer's built-in HTTPS — TLS is handled by host nginx
        sed -i "s|^HTTPS_PORT=|#HTTPS_PORT=|" "$config" 2>/dev/null || true

        log "Restarting JumpServer on port $JUMPSERVER_HTTP_PORT..."
        "$JUMPSERVER_DIR/jmsctl.sh" start || \
            die "Failed to start JumpServer after port reconfiguration."
    else
        warn "JumpServer config file not found under $JUMPSERVER_DIR — port reconfiguration skipped."
        warn "JumpServer may still be on port 80; nginx will not be able to bind port 80."
        warn "Manually set HTTP_PORT=$JUMPSERVER_HTTP_PORT in the JumpServer config and restart."
    fi

    # Health check — wait up to 3 minutes
    log "Waiting for JumpServer to become ready on port $JUMPSERVER_HTTP_PORT..."
    local retries=36
    while [[ $retries -gt 0 ]]; do
        if curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
               "http://127.0.0.1:${JUMPSERVER_HTTP_PORT}/" 2>/dev/null | grep -qE "^[23]"; then
            ok "JumpServer is healthy on port $JUMPSERVER_HTTP_PORT"
            return 0
        fi
        sleep 5
        (( retries-- ))
        log "Still waiting... ($retries checks remaining)"
    done

    warn "JumpServer did not respond within 3 minutes."
    warn "Check status with: $JUMPSERVER_DIR/jmsctl.sh status"
}

# Find the JumpServer config file across known locations/versions
find_js_config() {
    # Resolve any symlink so find and -f tests hit the real filesystem path
    local actual_dir
    actual_dir=$(readlink -f "$JUMPSERVER_DIR" 2>/dev/null || echo "$JUMPSERVER_DIR")

    local candidates=(
        "$actual_dir/config/config.txt"
        "$actual_dir/config.txt"
        "$actual_dir/.env"
        "$actual_dir/compose/.env"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && echo "$f" && return
    done

    # Fallback: search the installer dir in case the layout changed between versions
    find "$actual_dir" -maxdepth 3 -name "config.txt" 2>/dev/null | head -1
}

# ── Phase 7: fail2ban ─────────────────────────────────────────────────────────
configure_fail2ban() {
    header "Phase 7: fail2ban"

    # Filter: detect repeated 401/403 responses in the JumpServer nginx access log
    cat > "$FAIL2BAN_FILTER" <<'F2B_FILTER'
[Definition]
failregex = ^<HOST> .* "(POST|GET) .* HTTP/\d\.\d" (401|403) .*$
ignoreregex =
F2B_FILTER

    cat > "$FAIL2BAN_JAIL" <<F2B_JAIL
# JumpServerCE fail2ban jails
# Managed by install.sh v${SCRIPT_VERSION}

[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

# Standard SSH on port 22
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 1h

# JumpServer Koko SSH gateway on port 2222
# Auth failures from Koko appear in auth.log via PAM/kernel logging
[jumpserver-koko]
enabled  = true
port     = 2222
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 1h

# JumpServer web: repeated HTTP 401/403 in nginx access log
[jumpserver-web]
enabled  = true
port     = http,https
filter   = jumpserver-web
logpath  = /var/log/nginx/jumpserver-access.log
maxretry = 10
findtime = 5m
bantime  = 1h
F2B_JAIL

    systemctl enable --now fail2ban
    systemctl restart fail2ban

    ok "fail2ban: sshd (port 22), koko (port 2222), web (ports 80/443)"
}

# ── Phase 8: Firewall ─────────────────────────────────────────────────────────
configure_ufw() {
    header "Phase 8: Firewall (ufw)"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp   comment 'SSH'
    ufw allow 80/tcp   comment 'HTTP (redirect to HTTPS)'
    ufw allow 443/tcp  comment 'HTTPS — JumpServer web UI'
    ufw allow 2222/tcp comment 'JumpServer Koko SSH gateway'

    ufw --force enable

    ok "ufw enabled: 22, 80, 443, 2222 open; all other ingress denied"
}

# ── Phase 9: Post-install summary ─────────────────────────────────────────────
print_summary() {
    header "Installation Complete"

    local cert_expiry
    cert_expiry=$(certbot certificates 2>/dev/null | awk '/Expiry Date/{print $3}' | head -1) || \
        cert_expiry="unknown"

    echo -e "${BOLD}${GREEN}JumpServerCE is installed and running.${NC}\n"

    printf "  %-20s %s\n" "Web URL:"         "https://${FQDN}"
    printf "  %-20s %s\n" "SSH gateway:"     "ssh <user>@${FQDN} -p 2222"
    printf "  %-20s %s\n" "Default login:"   "admin / ChangeMe"
    printf "  %-20s %s\n" "TLS cert expiry:" "$cert_expiry"
    printf "  %-20s %s\n" "Log file:"        "$LOG_FILE"
    echo ""
    echo -e "  ${YELLOW}ACTION REQUIRED: Change the admin password immediately after first login.${NC}"
    echo ""
    echo "  Service status:"
    printf "    %-12s %s\n" "nginx:"    "$(systemctl is-active nginx    2>/dev/null || echo unknown)"
    printf "    %-12s %s\n" "fail2ban:" "$(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
    echo ""
    echo "  Manage JumpServer:"
    printf "    %s\n" "$JUMPSERVER_DIR/jmsctl.sh status"
    printf "    %s\n" "$JUMPSERVER_DIR/jmsctl.sh restart"
    printf "    %s\n" "$JUMPSERVER_DIR/jmsctl.sh stop"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Ensure log directory and file exist before any tee calls
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       JumpServerCE Installer v${SCRIPT_VERSION}                ║"
    echo "║       Ubuntu 24.04 LTS · HTTPS · fail2ban            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}  Log: $LOG_FILE\n"

    require_root
    parse_args "$@"

    # Idempotency: detect and offer to reinstall or uninstall
    if jumpserver_installed; then
        handle_existing_install
    fi

    preflight_checks
    collect_fqdn
    install_packages
    obtain_certificate
    install_jumpserver
    configure_nginx
    configure_fail2ban
    configure_ufw
    print_summary
}

main "$@"
