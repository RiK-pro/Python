#!/usr/bin/env bash
set -Eeuo pipefail

SELFSTEAL_SCRIPT_URL="${SELFSTEAL_SCRIPT_URL:-https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh}"
REMNANODE_DIR="${REMNANODE_DIR:-/opt/remnanode}"
REMNANODE_IMAGE="${REMNANODE_IMAGE:-remnawave/node:latest}"
REMNANODE_SERVICE_NAME="${REMNANODE_SERVICE_NAME:-remnanode}"
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-2222}"
DEFAULT_SELFSTEAL_PORT="${DEFAULT_SELFSTEAL_PORT:-9443}"
DEFAULT_SELFSTEAL_TEMPLATE="${DEFAULT_SELFSTEAL_TEMPLATE:-1}"
DEFAULT_SELFSTEAL_DOMAIN="${DEFAULT_SELFSTEAL_DOMAIN:-nld3.pink-service.ru}"
CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-600}"

CERT_DIR="$REMNANODE_DIR/xray-ssl"
COMPOSE_FILE="$REMNANODE_DIR/docker-compose.yml"
ENV_FILE="$REMNANODE_DIR/.env"
DEFAULT_CERT_FILE="$CERT_DIR/fullchain.pem"
DEFAULT_KEY_PEM="$CERT_DIR/privkey.pem"
DEFAULT_KEY_KEY="$CERT_DIR/privkey.key"

STATUS_NODE="PENDING"
STATUS_SELFSTEAL="PENDING"
STATUS_OPTIMIZATION="PENDING"
STATUS_SCANNER="PENDING"
NOTE_NODE=""
NOTE_SELFSTEAL=""
NOTE_OPTIMIZATION=""
NOTE_SCANNER=""

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
info() { echo "-- $*"; }
warn() { echo "WARN: $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run as root (sudo -i)"
  fi
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_default() {
  local var_name="$1"
  local question="$2"
  local default_value="$3"
  local value=""
  read -r -p "$question" value || true
  value="$(trim "$value")"
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf -v "$var_name" '%s' "$value"
}

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_int_1_11() {
  [[ "${1:-}" =~ ^([1-9]|1[0-1])$ ]]
}

print_summary() {
  echo
  echo "Checklist:"
  echo "- Нода: ${STATUS_NODE}${NOTE_NODE:+ (${NOTE_NODE})}"
  echo "- Селфстил: ${STATUS_SELFSTEAL}${NOTE_SELFSTEAL:+ (${NOTE_SELFSTEAL})}"
  echo "- Оптимизация сервера: ${STATUS_OPTIMIZATION}${NOTE_OPTIMIZATION:+ (${NOTE_OPTIMIZATION})}"
  echo "- Защита от сканеров: ${STATUS_SCANNER}${NOTE_SCANNER:+ (${NOTE_SCANNER})}"
}
trap print_summary EXIT

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp "$file" "${file}.bak_${ts}"
    ok "backup created: ${file}.bak_${ts}"
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    ok "docker is already installed"
  else
    info "installing docker via official script"
    curl -fsSL https://get.docker.com | sh
    ok "docker installed"
  fi

  docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing after docker install"
}

write_remnanode_files() {
  local node_port="$1"
  local secret_key="$2"

  mkdir -p "$REMNANODE_DIR" "$CERT_DIR"
  chmod 700 "$CERT_DIR" || true

  backup_if_exists "$ENV_FILE"
  backup_if_exists "$COMPOSE_FILE"

  {
    printf 'NODE_PORT=%s\n' "$node_port"
    printf 'SECRET_KEY=%s\n' "$secret_key"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  cat > "$COMPOSE_FILE" <<EOF2
services:
  ${REMNANODE_SERVICE_NAME}:
    container_name: ${REMNANODE_SERVICE_NAME}
    hostname: ${REMNANODE_SERVICE_NAME}
    image: ${REMNANODE_IMAGE}
    restart: always
    network_mode: host
    env_file:
      - .env
    environment:
      - NODE_PORT=\${NODE_PORT}
      - SECRET_KEY=\${SECRET_KEY}
    volumes:
      - ./xray-ssl:/var/lib/remnawave/configs/xray/ssl
EOF2

  ok "written: $COMPOSE_FILE"
  ok "written: $ENV_FILE"
}

start_remnanode() {
  info "starting remnanode"
  (
    cd "$REMNANODE_DIR"
    docker compose up -d
    docker compose ps "$REMNANODE_SERVICE_NAME"
  )
}

set_sysctl_setting() {
  local key="$1"
  local value="$2"
  local conf_file="/etc/sysctl.conf"
  local escaped

  escaped="$(printf '%s' "$key" | sed -e 's/[.[\\*^$()+?{}|]/\\\\&/g')"

  if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$conf_file"; then
    sed -i -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*|${key}=${value}|" "$conf_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$conf_file"
  fi
}

configure_bbr() {
  set_sysctl_setting "net.core.default_qdisc" "fq"
  set_sysctl_setting "net.ipv4.tcp_congestion_control" "bbr"

  sysctl -p >/tmp/remnanode-sysctl.log 2>&1 || {
    cat /tmp/remnanode-sysctl.log >&2 || true
    return 1
  }

  local current_cc=""
  local current_qdisc=""
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  [[ "$current_cc" == "bbr" ]] || return 1
  [[ "$current_qdisc" == "fq" ]] || return 1

  ok "BBR enabled: tcp_congestion_control=$current_cc, default_qdisc=$current_qdisc"
}

install_traffic_guard() {
  export DEBIAN_FRONTEND=noninteractive

  if command -v debconf-set-selections >/dev/null 2>&1; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections || true
  fi

  apt-get update -y
  apt-get install -y curl ipset iptables iptables-persistent rsyslog cron

  curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | bash
  [[ -x /usr/local/bin/traffic-guard ]] || die "traffic-guard binary not found at /usr/local/bin/traffic-guard"

  cat > /usr/local/sbin/traffic-guard-apply.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/traffic-guard full \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/antiscanner.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/government_networks.list

netfilter-persistent save || true
EOF2

  chmod 755 /usr/local/sbin/traffic-guard-apply.sh
  /usr/local/sbin/traffic-guard-apply.sh

  cat > /etc/cron.d/traffic-guard-update <<'EOF2'
17 3 * * * root /usr/local/sbin/traffic-guard-apply.sh >> /var/log/traffic-guard-update.log 2>&1
EOF2

  chmod 644 /etc/cron.d/traffic-guard-update
  systemctl enable --now cron

  ok "traffic-guard installed and cron enabled (daily at 03:17)"
}

wait_for_node_certificates() {
  local cert_file="$DEFAULT_CERT_FILE"
  local key_file="$DEFAULT_KEY_PEM"
  local waited=0

  if [[ -s "$DEFAULT_KEY_PEM" && ! -e "$DEFAULT_KEY_KEY" ]]; then
    ln -sfn "$DEFAULT_KEY_PEM" "$DEFAULT_KEY_KEY" || true
  fi

  if [[ -s "$DEFAULT_KEY_KEY" ]]; then
    key_file="$DEFAULT_KEY_KEY"
  fi

  while [[ $waited -lt $CERT_WAIT_SECONDS ]]; do
    if [[ -s "$cert_file" && -s "$key_file" ]]; then
      ok "certificates detected in $CERT_DIR"
      return 0
    fi

    if [[ $waited -eq 0 ]]; then
      warn "certificates are not present yet"
      echo "Do this in panel now:"
      echo "1) Nodes -> Management -> open your node and finish creation"
      echo "2) Select Config Profile and push/apply it to node"
      echo "3) Ensure profile contains certificateFile/keyFile paths"
      echo
      echo "Waiting up to ${CERT_WAIT_SECONDS}s for certs in $CERT_DIR ..."
    fi

    sleep 5
    waited=$((waited + 5))
    if [[ -s "$DEFAULT_KEY_KEY" ]]; then
      key_file="$DEFAULT_KEY_KEY"
    fi
  done

  warn "certificates were not detected automatically"
  return 1
}

pick_key_file() {
  if [[ -s "$DEFAULT_KEY_KEY" ]]; then
    printf '%s' "$DEFAULT_KEY_KEY"
    return 0
  fi
  if [[ -s "$DEFAULT_KEY_PEM" ]]; then
    printf '%s' "$DEFAULT_KEY_PEM"
    return 0
  fi
  return 1
}

install_selfsteal() {
  local domain="${SELFSTEAL_DOMAIN:-}"
  local template="${SELFSTEAL_TEMPLATE:-}"
  local port="${SELFSTEAL_PORT:-}"
  local cert="${SELFSTEAL_SSL_CERT:-$DEFAULT_CERT_FILE}"
  local key="${SELFSTEAL_SSL_KEY:-}"

  domain="$(trim "$domain")"
  template="$(trim "$template")"
  port="$(trim "$port")"

  if [[ -z "$domain" ]]; then
    prompt_default domain "Selfsteal domain (SNI/serverName) [${DEFAULT_SELFSTEAL_DOMAIN}]: " "$DEFAULT_SELFSTEAL_DOMAIN"
  fi
  [[ -n "$domain" ]] || die "domain is required"

  if [[ -z "$template" ]]; then
    prompt_default template "Selfsteal template 1-11 [${DEFAULT_SELFSTEAL_TEMPLATE}]: " "$DEFAULT_SELFSTEAL_TEMPLATE"
  fi
  is_int_1_11 "$template" || die "template must be 1..11 (got: $template)"

  if [[ -z "$port" ]]; then
    prompt_default port "Selfsteal local tcp port [${DEFAULT_SELFSTEAL_PORT}]: " "$DEFAULT_SELFSTEAL_PORT"
  fi
  is_int "$port" || die "port must be numeric (got: $port)"

  if [[ -z "$key" ]]; then
    key="$(pick_key_file || true)"
  fi
  [[ -n "$key" ]] || die "key file not found in $CERT_DIR"

  [[ -s "$cert" ]] || die "certificate file not found or empty: $cert"
  [[ -s "$key" ]] || die "key file not found or empty: $key"

  chmod 600 "$key" 2>/dev/null || true

  info "installing selfsteal with certs from remnanode mount"
  echo "  cert: $cert"
  echo "  key:  $key"
  echo "  domain: $domain"
  echo "  template: $template"
  echo "  port: 127.0.0.1:${port}"

  bash <(curl -fsSL "$SELFSTEAL_SCRIPT_URL") @ \
    --nginx --tcp --force \
    --domain "$domain" \
    --port "$port" \
    --ssl-cert "$cert" \
    --ssl-key "$key" \
    --template "$template" \
    install

  ok "selfsteal installed"

  local l443=""
  l443="$(ss -ltnp 2>/dev/null | grep -E ':443\\b' || true)"
  if echo "$l443" | grep -q 'rw-core'; then
    ok "port 443 is owned by rw-core"
  else
    warn "port 443 is not owned by rw-core; check remnanode/rw-core status"
  fi

  local code=""
  code="$(curl -skI "https://${domain}/" --resolve "${domain}:443:127.0.0.1" --max-time 5 | awk 'NR==1{print $2; exit}' || true)"
  if [[ "$code" == "200" ]]; then
    ok "fallback via 443 returns HTTP 200"
  else
    warn "fallback via 443 returned HTTP ${code:-none}"
  fi

  echo
  echo "Use these values in panel Xray profile:"
  echo "  realitySettings.dest: \"127.0.0.1:${port}\""
  echo "  realitySettings.xver: 1"
  echo "  realitySettings.serverNames: [\"${domain}\"]"
  echo "  settings.fallbacks: [{\"dest\":\"127.0.0.1:${port}\",\"xver\":1}]"
  echo "  certificates[0].certificateFile: \"/var/lib/remnawave/configs/xray/ssl/fullchain.pem\""
  echo "  certificates[0].keyFile: \"/var/lib/remnawave/configs/xray/ssl/privkey.key\" (or privkey.pem)"
}

main() {
  require_root
  need_cmd curl
  need_cmd awk
  need_cmd sed
  need_cmd grep
  need_cmd ss

  STATUS_NODE="IN_PROGRESS"
  install_docker_if_needed

  local node_port="$DEFAULT_NODE_PORT"
  is_int "$node_port" || die "node port must be numeric (got: $node_port)"

  local secret_key="${REMNANODE_SECRET_KEY:-}"
  secret_key="$(printf '%s' "$secret_key" | tr -d '\r\n')"
  secret_key="$(trim "$secret_key")"
  if [[ -z "$secret_key" ]]; then
    prompt_default secret_key "Paste SECRET_KEY from panel: " ""
    secret_key="$(printf '%s' "$secret_key" | tr -d '\r\n')"
    secret_key="$(trim "$secret_key")"
  fi
  [[ -n "$secret_key" ]] || die "SECRET_KEY is required"

  write_remnanode_files "$node_port" "$secret_key"
  start_remnanode
  STATUS_NODE="OK"
  NOTE_NODE="compose up completed"

  STATUS_OPTIMIZATION="IN_PROGRESS"
  if configure_bbr; then
    STATUS_OPTIMIZATION="OK"
    NOTE_OPTIMIZATION="BBR enabled"
  else
    STATUS_OPTIMIZATION="FAIL"
    NOTE_OPTIMIZATION="BBR configuration failed"
    warn "BBR configuration failed"
  fi

  STATUS_SCANNER="IN_PROGRESS"
  if install_traffic_guard; then
    STATUS_SCANNER="OK"
    NOTE_SCANNER="traffic-guard active"
  else
    STATUS_SCANNER="FAIL"
    NOTE_SCANNER="traffic-guard installation failed"
    warn "traffic-guard installation failed"
  fi

  STATUS_SELFSTEAL="IN_PROGRESS"
  if ! wait_for_node_certificates; then
    STATUS_SELFSTEAL="FAIL"
    NOTE_SELFSTEAL="certificates not received from panel yet"
    warn "continue with selfsteal only after certs appear in $CERT_DIR"
    echo "Re-run this script later with:"
    echo "  REMNANODE_DIR=$REMNANODE_DIR SELFSTEAL_DOMAIN=<domain> bash $0"
    exit 2
  fi

  if install_selfsteal; then
    STATUS_SELFSTEAL="OK"
    NOTE_SELFSTEAL="installed and checked"
  else
    STATUS_SELFSTEAL="FAIL"
    NOTE_SELFSTEAL="installation failed"
    exit 2
  fi

  echo
  ok "completed"
  echo "Node compose: $COMPOSE_FILE"
  echo "Node env:     $ENV_FILE"
  echo "Node cert dir:$CERT_DIR"

  if [[ "$STATUS_OPTIMIZATION" == "FAIL" || "$STATUS_SCANNER" == "FAIL" ]]; then
    exit 3
  fi

  exit 0
}

main "$@"
