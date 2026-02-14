#!/usr/bin/env bash
set -Eeuo pipefail

# Install selfsteal on a node in "Quattro-style":
# - 443 stays for Xray/rw-core
# - selfsteal runs on 127.0.0.1:<port> (default 9443) in TCP mode
# - uses pre-provisioned wildcard cert/key (same on every node)
#
# Run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/<branch>/vkcloud/selfsteal_install.sh)
#
# Optional env overrides:
#   SELFSTEAL_DOMAIN, SELFSTEAL_TEMPLATE, SELFSTEAL_PORT
#   SELFSTEAL_SSL_CERT, SELFSTEAL_SSL_KEY
#   SELFSTEAL_CERT_URL, SELFSTEAL_KEY_URL   (download cert/key if missing)

SELFSTEAL_SCRIPT_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"

DEFAULT_CERT="/etc/selfsteal/certs/fullchain.pem"
DEFAULT_KEY="/etc/selfsteal/certs/privkey.pem"
DEFAULT_PORT="9443"
DEFAULT_TEMPLATE="1"

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

as_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run as root (sudo -i)"
  fi
}

sanitize_term() {
  # selfsteal.sh uses `clear`/tput; in non-tty sessions TERM may be unset or "unknown"
  if [[ -z "${TERM:-}" || "${TERM:-}" == "unknown" ]]; then
    export TERM="xterm"
  fi
}

prompt() {
  local var="$1" msg="$2" def="${3:-}"
  local val=""
  read -r -p "$msg" val || true
  val="$(printf '%s' "$val" | xargs)"
  if [[ -z "$val" ]]; then
    val="$def"
  fi
  printf -v "$var" '%s' "$val"
}

is_int_1_11() { [[ "${1:-}" =~ ^([1-9]|1[0-1])$ ]]; }

download_if_needed() {
  local cert="$1" key="$2"
  local cert_url="${SELFSTEAL_CERT_URL:-}"
  local key_url="${SELFSTEAL_KEY_URL:-}"

  if [[ -f "$cert" && -f "$key" ]]; then
    return 0
  fi

  if [[ -n "$cert_url" && -n "$key_url" ]]; then
    ok "cert/key missing locally, downloading from provided URLs..."
    mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
    curl -fsSL "$cert_url" -o "$cert"
    curl -fsSL "$key_url" -o "$key"
    chmod 600 "$cert" "$key" || true
    return 0
  fi

  return 1
}

print_copy_instructions() {
  local cert="$1" key="$2"
  echo
  echo "Certificates are missing on this node."
  echo
  echo "To keep the SAME cert/key on every RR node, you must copy them from your control host:"
  echo
  echo "  sudo -i mkdir -p /etc/selfsteal/certs && sudo -i chmod 700 /etc/selfsteal/certs"
  echo "  scp fullchain.pem root@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<NODE_IP>'):$cert"
  echo "  scp privkey.pem   root@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<NODE_IP>'):$key"
  echo
  echo "Then rerun this script."
  echo
  echo "Alternative (less safe): set env vars SELFSTEAL_CERT_URL and SELFSTEAL_KEY_URL to download."
}

main() {
  as_root
  sanitize_term
  need bash
  need curl
  need ss

  local domain="${SELFSTEAL_DOMAIN:-}"
  domain="$(printf '%s' "$domain" | xargs)"
  if [[ -z "$domain" ]]; then
    prompt domain "Domain (SNI/serverName) [nld3.pink-service.ru]: " "nld3.pink-service.ru"
  fi
  [[ -n "$domain" ]] || die "domain is required"

  local template="${SELFSTEAL_TEMPLATE:-}"
  template="$(printf '%s' "$template" | xargs)"
  if [[ -z "$template" ]]; then
    prompt template "Template 1-11 [${DEFAULT_TEMPLATE}]: " "$DEFAULT_TEMPLATE"
  fi
  is_int_1_11 "$template" || die "template must be 1..11 (got: $template)"

  local port="${SELFSTEAL_PORT:-$DEFAULT_PORT}"
  port="$(printf '%s' "$port" | xargs)"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be numeric (got: $port)"

  local cert="${SELFSTEAL_SSL_CERT:-$DEFAULT_CERT}"
  local key="${SELFSTEAL_SSL_KEY:-$DEFAULT_KEY}"

  mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
  chmod 700 /etc/selfsteal/certs 2>/dev/null || true

  if ! download_if_needed "$cert" "$key"; then
    if [[ ! -f "$cert" || ! -f "$key" ]]; then
      print_copy_instructions "$cert" "$key"
      exit 2
    fi
  fi

  chmod 600 "$cert" "$key" 2>/dev/null || true

  echo
  echo "Installing selfsteal:"
  echo "  domain=$domain"
  echo "  template=$template"
  echo "  listen=127.0.0.1:$port (TCP)"
  echo

  bash <(curl -fsSL "$SELFSTEAL_SCRIPT_URL") @ \
    --nginx --tcp --force \
    --domain "$domain" --port "$port" \
    --ssl-cert "$cert" --ssl-key "$key" \
    --template "$template" \
    install

  echo
  ok "selfsteal installed"

  echo
  echo "Quick result:"
  echo "- 443 must be owned by rw-core"
  echo "- fallback via :443 must return 200"
  echo

  local l443=""
  l443="$(ss -ltnp 2>/dev/null | grep -E ":443\\b" || true)"
  echo "$l443" | grep -q "rw-core" && ok "443 owned by rw-core" || echo "WARN: 443 not owned by rw-core (check remnanode/rw-core)"

  local code=""
  code="$(curl -skI "https://$domain/" --resolve "$domain:443:127.0.0.1" --max-time 5 | awk 'NR==1{print $2; exit}' || true)"
  [[ "$code" == "200" ]] && ok "fallback via :443 -> HTTP 200" || die "fallback via :443 returned HTTP ${code:-none}"

  echo
  echo "Remnawave/Xray settings to match this node:"
  echo "  realitySettings.dest: \"127.0.0.1:${port}\""
  echo "  realitySettings.xver: 1"
  echo "  realitySettings.serverNames: [\"${domain}\"]"
  echo "  settings.fallbacks: [{\"dest\":\"127.0.0.1:${port}\",\"xver\":1}]"
  echo
  echo "Reminder: Let's Encrypt certs are valid for 90 days. Rotate about every 60 days."
}

main "$@"

