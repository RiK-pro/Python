#!/usr/bin/env bash
set -euo pipefail

# -------------------- settings --------------------
SINCE_HOURS="${SINCE_HOURS:-24}"
SINCE_EXPR="${SINCE_EXPR:-${SINCE_HOURS} hours ago}"
TOP_N="${TOP_N:-10}"

# Force colors if you want:
#   FORCE_COLOR=1 bash <(curl -fsSL URL)
FORCE_COLOR="${FORCE_COLOR:-0}"

# -------------------- colors / ui --------------------
is_tty() { [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; }

USE_COLOR=0
if [[ "$FORCE_COLOR" == "1" ]] || is_tty; then USE_COLOR=1; fi

c() { # c "1;31" "text"
  if [[ "$USE_COLOR" == "1" ]]; then printf "\033[%sm%s\033[0m" "$1" "$2"; else printf "%s" "$2"; fi
}

ok()   { printf "%s %s\n" "$(c "0;92" "[OK]")"   "$*"; }
info() { printf "%s %s\n" "$(c "1;36" "[..]")"   "$*"; }
warn() { printf "%s %s\n" "$(c "1;33" "[WARN]")" "$*"; }
crit() { printf "%s %s\n" "$(c "1;31" "[CRIT]")" "$*"; }

hr()   { printf "%s\n" "$(c "1;90" "------------------------------------------------------------")"; }

spinner_run() {
  local msg="$1"; shift
  if is_tty; then
    local pid spin='-\|/' i=0
    printf "%s " "$(c "1;36" "$msg")"
    ( "$@" ) & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      printf "\b%s" "${spin:i++%4:1}"
      sleep 0.08
    done
    wait "$pid"
    printf "\b%s\n" "$(c "0;92" "✓")"
  else
    "$@"
  fi
}

to_int() { awk 'BEGIN{print int('"${1:-0}"')}'; }

# -------------------- helpers --------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

mem_report() {
  local mt ma st su
  mt=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  ma=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
  st=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
  su=$(awk '/SwapFree:/ {print $2}' /proc/meminfo)

  # KB -> MB
  local mt_mb ma_mb st_mb sf_mb used_swap_kb used_swap_mb
  mt_mb=$((mt/1024))
  ma_mb=$((ma/1024))
  st_mb=$((st/1024))
  sf_mb=$((su/1024))
  used_swap_kb=$((st - su))
  used_swap_mb=$((used_swap_kb/1024))

  echo "MEM_TOTAL_MB=$mt_mb"
  echo "MEM_AVAIL_MB=$ma_mb"
  echo "SWAP_TOTAL_MB=$st_mb"
  echo "SWAP_USED_MB=$used_swap_mb"
}

disk_report() {
  df -h / | awk 'NR==2{print $2, $3, $4, $5}'
}

journal_size_mb() {
  if have_cmd journalctl; then
    local s
    s=$(journalctl --disk-usage 2>/dev/null || true)
    # try extract MB-ish number
    # example: "take up 1.9G"
    local num unit
    num=$(echo "$s" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || echo "")
    unit=$(echo "$s" | grep -oE '[KMGTP]B?|[KMGTP]' | head -n1 || echo "")
    if [[ -n "$num" && -n "$unit" ]]; then
      # rough convert to MB
      awk -v n="$num" -v u="$unit" 'BEGIN{
        if(u=="K"||u=="KB") print int(n/1024);
        else if(u=="M"||u=="MB") print int(n);
        else if(u=="G"||u=="GB") print int(n*1024);
        else if(u=="T"||u=="TB") print int(n*1024*1024);
        else print -1
      }'
    else
      echo -1
    fi
  else
    echo -1
  fi
}

count_conntrack_drops() {
  if have_cmd journalctl; then
    sudo journalctl -k --since "$SINCE_EXPR" --no-pager 2>/dev/null \
      | egrep -ci "nf_conntrack: table full|dropping packet" || true
  else
    # fallback
    sudo dmesg 2>/dev/null | egrep -ci "nf_conntrack: table full|dropping packet" || true
  fi
}

count_oom_lines() {
  if have_cmd journalctl; then
    sudo journalctl -k --since "$SINCE_EXPR" --no-pager 2>/dev/null \
      | egrep -ci "Out of memory|Killed process|oom-kill|oom_kill_process" || true
  else
    sudo dmesg 2>/dev/null | egrep -ci "Out of memory|Killed process|oom-kill|oom_kill_process" || true
  fi
}

conntrack_read() {
  local cnt_file="/proc/sys/net/netfilter/nf_conntrack_count"
  local max_file="/proc/sys/net/netfilter/nf_conntrack_max"
  if [[ -r "$cnt_file" && -r "$max_file" ]]; then
    echo "CT_OK=1"
    echo "CT_COUNT=$(cat "$cnt_file")"
    echo "CT_MAX=$(cat "$max_file")"
  else
    echo "CT_OK=0"
    echo "CT_COUNT=0"
    echo "CT_MAX=0"
  fi
}

top_rss() {
  ps -eo pid,user,comm,rss,%mem,etime --sort=-rss | head -n "$((TOP_N+1))"
}

# -------------------- main --------------------
main() {
  hr
  printf "%s\n" "$(c "1;97" "VPN Node Healthcheck (since: $SINCE_EXPR)")"
  hr

  # MEM/SWAP
  local mem_env
  mem_env="$(mem_report)"
  eval "$mem_env"

  printf "[MEM]  total=%sMB  available=%sMB\n" "$MEM_TOTAL_MB" "$MEM_AVAIL_MB"

  if [[ "$SWAP_TOTAL_MB" -le 0 ]]; then
    printf "[SWAP] total=0MB  (swap отсутствует)\n"
  else
    local swap_pct=0
    if [[ "$SWAP_TOTAL_MB" -gt 0 ]]; then swap_pct=$((SWAP_USED_MB*100/SWAP_TOTAL_MB)); fi
    printf "[SWAP] total=%sMB  used=%sMB  (%s%%)\n" "$SWAP_TOTAL_MB" "$SWAP_USED_MB" "$swap_pct"
  fi

  # DISK
  local disk_line
  disk_line="$(disk_report)"
  # size used avail use%
  local dsz dus dav dup
  read -r dsz dus dav dup <<<"$disk_line"
  printf "[DISK] / %s/%s used, %s avail, %s used\n" "$dus" "$dsz" "$dav" "$dup"

  # JOURNAL
  if have_cmd journalctl; then
    local jdu
    jdu="$(journalctl --disk-usage 2>/dev/null || true)"
    local jmb
    jmb="$(journal_size_mb)"
    if [[ "$jmb" -ge 0 ]]; then
      printf "[JOURNAL] %s (~%sMB)\n" "$jdu" "$jmb"
    else
      printf "[JOURNAL] %s\n" "$jdu"
    fi
  else
    printf "[JOURNAL] journalctl not found\n"
  fi

  echo

  # CONNTRACK
  echo "[CONNTRACK]"
  local ct_env
  ct_env="$(conntrack_read)"
  eval "$ct_env"

  if [[ "$CT_OK" == "1" ]]; then
    local ct_pct=$((CT_COUNT*100/CT_MAX))
    printf "  usage: %s/%s (%s%%)\n" "$CT_COUNT" "$CT_MAX" "$ct_pct"
  else
    printf "  usage: недоступно (нет /proc/sys/net/netfilter/nf_conntrack_*)\n"
  fi

  local drops
  spinner_run "  counting drops" bash -c 'true'
  drops="$(count_conntrack_drops)"
  printf "  drops in logs: %s\n" "${drops:-0}"
  echo

  # OOM
  local oom
  spinner_run "[OOM] scanning kernel log" bash -c 'true'
  oom="$(count_oom_lines)"
  printf "[OOM] kernel OOM lines: %s\n" "${oom:-0}"
  echo

  # TOP RSS
  echo "[TOP RSS]"
  top_rss
  echo
  hr

  # -------------------- recommendations --------------------
  local status=0   # 0 OK, 1 WARN, 2 CRIT
  echo "Рекомендации:"

  # conntrack recs
  if [[ "${drops:-0}" -gt 0 ]]; then
    crit "Есть conntrack drops (${drops}). Это влияет на соединения."
    status=2
  else
    ok "Conntrack drops не найдено."
  fi

  if [[ "$CT_OK" == "1" ]]; then
    local ct_pct=$((CT_COUNT*100/CT_MAX))
    if [[ "$CT_MAX" -le 8192 ]]; then
      warn "nf_conntrack_max маленький (${CT_MAX}). Для VPN/NAT это часто мало."
      status=$(( status<1 ? 1 : status ))
    fi
    if [[ "$ct_pct" -ge 90 ]]; then
      warn "Conntrack близко к лимиту: ${ct_pct}% (${CT_COUNT}/${CT_MAX})."
      status=$(( status<1 ? 1 : status ))
    fi
  else
    warn "Conntrack счётчики недоступны. Если нужен NAT/iptables — проверь модуль nf_conntrack."
    status=$(( status<1 ? 1 : status ))
  fi

  # oom recs
  if [[ "${oom:-0}" -gt 0 ]]; then
    crit "Были OOM события за период: ${oom}. Нужно снижать память/добавлять swap."
    status=2
  else
    ok "OOM за период не найдено."
  fi

  # swap recs
  if [[ "$SWAP_TOTAL_MB" -le 0 ]]; then
    warn "Swap отсутствует. Рекомендация: сделать swap 1024–2048MB."
    status=$(( status<1 ? 1 : status ))
  else
    local swap_pct=$((SWAP_USED_MB*100/SWAP_TOTAL_MB))
    if [[ "$SWAP_TOTAL_MB" -lt 512 ]]; then
      warn "Swap есть, но маленький (${SWAP_TOTAL_MB}MB). Лучше 1024–2048MB."
      status=$(( status<1 ? 1 : status ))
    fi
    if [[ "$swap_pct" -ge 70 ]]; then
      warn "Swap сильно занят (${swap_pct}%). Ожидай лаги/вылеты."
      status=$(( status<1 ? 1 : status ))
    else
      ok "Swap ок."
    fi
  fi

  # mem recs
  if [[ "$MEM_AVAIL_MB" -lt 120 ]]; then
    warn "MemAvailable низкий (${MEM_AVAIL_MB}MB). Риск лагов/OOM."
    status=$(( status<1 ? 1 : status ))
  else
    ok "Память по доступности ок."
  fi

  # journald recs
  local jmb
  jmb="$(journal_size_mb)"
  if [[ "$jmb" -ge 1024 ]]; then
    warn "journald крупный (~${jmb}MB). Можно уменьшить vacuum/лимит SystemMaxUse."
    status=$(( status<1 ? 1 : status ))
  else
    ok "journald по размеру ок."
  fi

  echo
  case "$status" in
    0) printf "%s\n" "STATUS: $(c "0;92" "OK")"; exit 0 ;;
    1) printf "%s\n" "STATUS: $(c "1;33" "WARNING")"; exit 1 ;;
    *) printf "%s\n" "STATUS: $(c "1;31" "CRITICAL")"; exit 2 ;;
  esac
}

main "$@"
