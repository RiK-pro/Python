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
CERT_HELPER_TAG="${CERT_HELPER_TAG:-rw_cert_sync_helper}"

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
RUN_NODE=1
RUN_SELFSTEAL=1
RUN_OPTIMIZATION=1
RUN_SCANNER=1
INSTALL_MODE_NAME="full"

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
info() { echo "-- $*"; }
warn() { echo "WARN: $*"; }

wait_for_apt_locks() {
  local timeout="${1:-600}"
  local waited=0
  local interval=5

  if ! command -v fuser >/dev/null 2>&1; then
    warn "fuser is not available; skipping apt lock wait"
    return 0
  fi

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/cache/apt/archives/lock >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( waited == 0 )); then
      warn "apt/dpkg is busy (likely unattended-upgrades), waiting for lock release..."
    fi
    if (( waited >= timeout )); then
      die "apt/dpkg lock was not released in ${timeout}s"
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done

  if (( waited > 0 )); then
    ok "apt/dpkg lock released after ${waited}s"
  fi
}

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

set_install_mode_flags() {
  local mode="$1"
  case "$mode" in
    1)
      RUN_NODE=1
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="full"
      ;;
    2)
      RUN_NODE=1
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="remnanode_only"
      ;;
    3)
      RUN_NODE=0
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="selfsteal_only"
      ;;
    4)
      RUN_NODE=1
      RUN_SELFSTEAL=1
      RUN_OPTIMIZATION=0
      RUN_SCANNER=0
      INSTALL_MODE_NAME="node_and_selfsteal"
      ;;
    5)
      RUN_NODE=1
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="node_opt_scanner"
      ;;
    6)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=1
      INSTALL_MODE_NAME="opt_and_scanner_only"
      ;;
    7)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=1
      RUN_SCANNER=0
      INSTALL_MODE_NAME="optimization_only"
      ;;
    8)
      RUN_NODE=0
      RUN_SELFSTEAL=0
      RUN_OPTIMIZATION=0
      RUN_SCANNER=1
      INSTALL_MODE_NAME="scanner_only"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

select_install_mode() {
  local mode="${INSTALL_MODE:-}"
  mode="$(trim "$mode")"

  if [[ -z "$mode" ]]; then
    echo
    echo "Select installation mode:"
    echo "  1) Full install (remnanode + selfsteal + optimization + scanner protection)"
    echo "  2) Only remnanode"
    echo "  3) Only selfsteal"
    echo "  4) Remnanode + selfsteal"
    echo "  5) Remnanode + optimization + scanner protection"
    echo "  6) Only optimization + scanner protection"
    echo "  7) Only optimization (BBR)"
    echo "  8) Only scanner protection (traffic-guard)"
    read -r -p "Mode [1]: " mode || true
    mode="$(trim "$mode")"
  fi

  if [[ -z "$mode" ]]; then
    mode="1"
  fi

  set_install_mode_flags "$mode" || die "invalid mode: $mode"
  ok "selected mode: ${mode} (${INSTALL_MODE_NAME})"
}

mark_skipped_steps() {
  if [[ "$RUN_NODE" -eq 0 ]]; then
    STATUS_NODE="SKIPPED"
    NOTE_NODE="not selected"
  fi
  if [[ "$RUN_SELFSTEAL" -eq 0 ]]; then
    STATUS_SELFSTEAL="SKIPPED"
    NOTE_SELFSTEAL="not selected"
  fi
  if [[ "$RUN_OPTIMIZATION" -eq 0 ]]; then
    STATUS_OPTIMIZATION="SKIPPED"
    NOTE_OPTIMIZATION="not selected"
  fi
  if [[ "$RUN_SCANNER" -eq 0 ]]; then
    STATUS_SCANNER="SKIPPED"
    NOTE_SCANNER="not selected"
  fi
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
    cap_add:
      - NET_ADMIN
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

  wait_for_apt_locks 900

  if command -v debconf-set-selections >/dev/null 2>&1; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections || true
  fi

  wait_for_apt_locks 900
  apt-get update -y
  wait_for_apt_locks 900
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
  local apply_attempt=1
  local max_attempts=5
  while (( apply_attempt <= max_attempts )); do
    wait_for_apt_locks 900
    if /usr/local/sbin/traffic-guard-apply.sh; then
      break
    fi
    if (( apply_attempt == max_attempts )); then
      die "traffic-guard apply failed after ${max_attempts} attempts"
    fi
    warn "traffic-guard apply failed (attempt ${apply_attempt}/${max_attempts}), retrying in 10s..."
    sleep 10
    apply_attempt=$((apply_attempt + 1))
  done

  cat > /etc/cron.d/traffic-guard-update <<'EOF2'
17 3 * * * root /usr/local/sbin/traffic-guard-apply.sh >> /var/log/traffic-guard-update.log 2>&1
EOF2

  chmod 644 /etc/cron.d/traffic-guard-update
  systemctl enable --now cron

  ok "traffic-guard installed and cron enabled (daily at 03:17)"
}

extract_inline_certs_from_active_config() {
  local helper_tag="$CERT_HELPER_TAG"
  local log_file="/tmp/remnanode-inline-cert-sync.log"

  if ! docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
    warn "container ${REMNANODE_SERVICE_NAME} is not running yet"
    return 1
  fi

  if docker exec -i -e CERT_TAG="$helper_tag" "$REMNANODE_SERVICE_NAME" sh >"$log_file" 2>&1 <<'EOSH'
set -eu

SOCK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_SOCKET_PATH=//p' | head -n1)"
TOK="$(tr '\0' '\n' </proc/1/environ | sed -n 's/^INTERNAL_REST_TOKEN=//p' | head -n1)"
[ -n "$SOCK" ] && [ -n "$TOK" ] || { echo "NO_RUNTIME_ENV"; exit 11; }

SOCK="$SOCK" TOK="$TOK" CERT_TAG="${CERT_TAG:-}" node <<'NODE'
const fs = require('fs');
const http = require('http');

const socketPath = process.env.SOCK;
const token = process.env.TOK;
const certTag = (process.env.CERT_TAG || '').trim();
const outDir = '/var/lib/remnawave/configs/xray/ssl';

function fail(msg, code) {
  console.error(msg);
  process.exit(code);
}

function hasInlineCert(ib) {
  const c = ib?.streamSettings?.tlsSettings?.certificates?.[0];
  return Array.isArray(c?.certificate) &&
    c.certificate.length > 0 &&
    Array.isArray(c?.key) &&
    c.key.length > 0;
}

http.get({ socketPath, path: `/internal/get-config?token=${token}` }, (res) => {
  let raw = '';
  res.on('data', (chunk) => {
    raw += chunk;
  });
  res.on('end', () => {
    let cfg;
    try {
      cfg = JSON.parse(raw || '{}');
    } catch {
      fail('BAD_CONFIG_JSON', 12);
    }

    const inbounds = Array.isArray(cfg?.inbounds) ? cfg.inbounds : [];

    let inbound = null;
    if (certTag) {
      inbound = inbounds.find((ib) => ib?.tag === certTag && hasInlineCert(ib)) || null;
    }
    if (!inbound) {
      inbound = inbounds.find((ib) => hasInlineCert(ib)) || null;
    }
    if (!inbound) {
      fail('NO_INLINE_CERTS_IN_ACTIVE_CONFIG', 13);
    }

    const certObj = inbound.streamSettings.tlsSettings.certificates[0];
    const certPem = `${certObj.certificate.join('\n')}\n`;
    const keyPem = `${certObj.key.join('\n')}\n`;

    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(`${outDir}/fullchain.pem`, certPem, { mode: 0o644 });
    fs.writeFileSync(`${outDir}/privkey.pem`, keyPem, { mode: 0o600 });

    try { fs.unlinkSync(`${outDir}/privkey.key`); } catch {}
    try {
      fs.symlinkSync(`${outDir}/privkey.pem`, `${outDir}/privkey.key`);
    } catch {
      fs.writeFileSync(`${outDir}/privkey.key`, keyPem, { mode: 0o600 });
    }

    console.log(`EXTRACTED_FROM_TAG=${inbound.tag}`);
  });
}).on('error', (err) => {
  fail(`REQUEST_ERROR:${err.message}`, 14);
});
NODE
EOSH
  then
    ok "inline certificates synced into ${CERT_DIR}"
    [[ -s "$DEFAULT_KEY_KEY" ]] || ln -sfn "$DEFAULT_KEY_PEM" "$DEFAULT_KEY_KEY" || true
    return 0
  fi

  warn "inline certificate sync failed ($(tail -n 1 "$log_file" 2>/dev/null || echo unknown))"
  return 1
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

    if (( waited % 10 == 0 )); then
      extract_inline_certs_from_active_config || true
      if [[ -s "$cert_file" && -s "$key_file" ]]; then
        ok "certificates extracted from active node config"
        return 0
      fi
    fi

    if [[ $waited -eq 0 ]]; then
      warn "certificates are not present yet"
      echo "Do this in panel now:"
      echo "1) Nodes -> Management -> open your node and finish creation"
      echo "2) Ensure inbound tag '${CERT_HELPER_TAG}' is included in node Active Inbounds"
      echo "3) Push/apply profile and restart Xray on node"
      echo "4) Ensure helper inbound has tlsSettings.certificates with certificateFile/keyFile paths"
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
    port="$DEFAULT_SELFSTEAL_PORT"
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
  select_install_mode
  mark_skipped_steps

  need_cmd awk
  need_cmd sed
  need_cmd grep

  if [[ "$RUN_NODE" -eq 1 || "$RUN_SELFSTEAL" -eq 1 || "$RUN_SCANNER" -eq 1 ]]; then
    need_cmd curl
  fi
  if [[ "$RUN_SELFSTEAL" -eq 1 ]]; then
    need_cmd ss
  fi

  if [[ "$RUN_NODE" -eq 1 ]]; then
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
  fi

  if [[ "$RUN_OPTIMIZATION" -eq 1 ]]; then
    STATUS_OPTIMIZATION="IN_PROGRESS"
    if configure_bbr; then
      STATUS_OPTIMIZATION="OK"
      NOTE_OPTIMIZATION="BBR enabled"
    else
      STATUS_OPTIMIZATION="FAIL"
      NOTE_OPTIMIZATION="BBR configuration failed"
      warn "BBR configuration failed"
    fi
  fi

  if [[ "$RUN_SCANNER" -eq 1 ]]; then
    STATUS_SCANNER="IN_PROGRESS"
    if install_traffic_guard; then
      STATUS_SCANNER="OK"
      NOTE_SCANNER="traffic-guard active"
    else
      STATUS_SCANNER="FAIL"
      NOTE_SCANNER="traffic-guard installation failed"
      warn "traffic-guard installation failed"
    fi
  fi

  if [[ "$RUN_SELFSTEAL" -eq 1 ]]; then
    if [[ "$RUN_NODE" -eq 0 ]]; then
      need_cmd docker
      if ! docker ps --format '{{.Names}}' | grep -qx "$REMNANODE_SERVICE_NAME"; then
        warn "container ${REMNANODE_SERVICE_NAME} is not running; cert extraction from runtime config may fail"
      fi
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
  fi

  echo
  ok "completed"
  if [[ "$RUN_NODE" -eq 1 ]]; then
    echo "Node compose: $COMPOSE_FILE"
    echo "Node env:     $ENV_FILE"
  fi
  if [[ "$RUN_SELFSTEAL" -eq 1 || "$RUN_NODE" -eq 1 ]]; then
    echo "Node cert dir:$CERT_DIR"
  fi

  if [[ "$STATUS_OPTIMIZATION" == "FAIL" || "$STATUS_SCANNER" == "FAIL" ]]; then
    exit 3
  fi

  exit 0
}

main "$@"
