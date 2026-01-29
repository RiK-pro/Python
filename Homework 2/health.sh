#!/usr/bin/env bash
set -euo pipefail

SINCE="${1:-24 hours ago}"

# Thresholds
CT_USAGE_WARN_PCT=80
MEM_AVAIL_WARN_MB=120
DISK_USE_WARN_PCT=85
JOURNAL_WARN_MB=800
SWAP_USED_WARN_PCT=70

STATE=0 # 0 OK, 1 WARN, 2 CRIT (nagios-style exit codes)
warn(){ log_warn "$*"; STATE=$(( STATE<1 ? 1 : STATE )); }
crit(){ log_crit "$*"; STATE=2; }

# ---------- Pretty UI (colors + spinner) ----------
IS_TTY=0
[[ -t 1 ]] && IS_TTY=1

if [[ "$IS_TTY" -eq 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"
  RESET="$(tput sgr0)" # reset text attributes (safer than reset) :contentReference[oaicite:1]{index=1}
  HIDE_CURSOR="$(tput civis)"; SHOW_CURSOR="$(tput cnorm)"
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""
  HIDE_CURSOR=""; SHOW_CURSOR=""
fi

hr(){ echo "${DIM}------------------------------------------------------------${RESET}"; }
h1(){ echo "${BOLD}${CYAN}$*${RESET}"; }
sec(){ echo "${BOLD}${BLUE}$*${RESET}"; }
ok(){ echo "${GREEN}OK${RESET}: $*"; }
log_warn(){ echo "${YELLOW}WARN${RESET}: $*"; }
log_crit(){ echo "${RED}CRIT${RESET}: $*"; }

spinner() {
  # spinner "Message..." command...
  local msg="$1"; shift
  if [[ "$IS_TTY" -ne 1 ]]; then
    "$@"
    return
  fi

  local frames='|/-\'
  local i=0
  echo -n "${DIM}${msg}... ${RESET}"
  echo -n "$HIDE_CURSOR"
  (
    "$@"
  ) >/tmp/.health_tmp_$$ 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf "\b%s" "${frames:i++%4:1}"
    sleep 0.1
  done
  wait "$pid" || true
  echo -n "$SHOW_CURSOR"
  printf "\b"
  echo "done"
}

to_int(){ awk '{print int($1)}'; }

# ---------- Collect ----------
CT_COUNT="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true)"
CT_MAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true)"

MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_AVAIL_MB="$(( MEM_AVAIL_KB / 1024 ))"
MEM_TOTAL_MB="$(( MEM_TOTAL_KB / 1024 ))"

SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"
SWAP_USED_KB="$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))"
SWAP_TOTAL_MB="$(( SWAP_TOTAL_KB / 1024 ))"
SWAP_USED_MB="$(( SWAP_USED_KB / 1024 ))"
SWAP_USED_PCT=0
if [[ "$SWAP_TOTAL_KB" -gt 0 ]]; then
  SWAP_USED_PCT="$(( (SWAP_USED_KB * 100) / SWAP_TOTAL_KB ))"
fi

DISK_USE_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}' | to_int)"
DISK_AVAIL="$(df -hP / | awk 'NR==2 {print $4}')"
DISK_USED="$(df -hP / | awk 'NR==2 {print $3}')"
DISK_SIZE="$(df -hP / | awk 'NR==2 {print $2}')"

# “heavy” parts with spinner
CT_DROPS=0
OOM_LINES=0
JOURNAL_LINE=""
spinner "Reading kernel journal (conntrack drops)" bash -lc \
  "journalctl -k --since '$SINCE' --no-pager 2>/dev/null | grep -Ei 'nf_conntrack:.*table full|dropping packet' | wc -l" \
  > /tmp/.health_ct_$$ || true
CT_DROPS="$(cat /tmp/.health_ct_$$ 2>/dev/null | to_int || echo 0)"
rm -f /tmp/.health_ct_$$

spinner "Reading kernel journal (OOM)" bash -lc \
  "journalctl -k --since '$SINCE' --no-pager 2>/dev/null | grep -Eai 'Out of memory: Killed process|oom-kill|invoked oom-killer' | wc -l" \
  > /tmp/.health_oom_$$ || true
OOM_LINES="$(cat /tmp/.health_oom_$$ 2>/dev/null | to_int || echo 0)"
rm -f /tmp/.health_oom_$$

spinner "Checking journald size" bash -lc "journalctl --disk-usage 2>/dev/null || true" > /tmp/.health_j_$$ || true
JOURNAL_LINE="$(cat /tmp/.health_j_$$ 2>/dev/null || true)"
rm -f /tmp/.health_j_$$

JOURNAL_MB=0
if [[ "$JOURNAL_LINE" =~ take\ up\ ([0-9.]+)([KMG]) ]]; then
  num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  JOURNAL_MB="$(awk -v n="$num" -v u="$unit" 'BEGIN{
    if(u=="K") printf "%.0f", n/1024;
    else if(u=="M") printf "%.0f", n;
    else if(u=="G") printf "%.0f", n*1024;
    else printf "0";
  }')"
fi

TOP_RSS="$(ps -eo pid,user,comm,rss,%mem,etime --sort=-rss | head -n 10)"

# ---------- Output ----------
hr
h1 "VPN Node Healthcheck ${DIM}(since: $SINCE)${RESET}"
hr

sec "[MEM]"
echo "total=${MEM_TOTAL_MB}MB  available=${MEM_AVAIL_MB}MB"

sec "[SWAP]"
echo "total=${SWAP_TOTAL_MB}MB  used=${SWAP_USED_MB}MB (${SWAP_USED_PCT}%)"

sec "[DISK]"
echo "/: ${DISK_USED}/${DISK_SIZE} used, ${DISK_AVAIL} avail, ${DISK_USE_PCT}% used"

sec "[JOURNAL]"
echo "${JOURNAL_LINE:-unknown} (~${JOURNAL_MB}MB)"

echo
sec "[CONNTRACK]"
if [[ -n "${CT_COUNT:-}" && -n "${CT_MAX:-}" && "${CT_MAX:-0}" -gt 0 ]]; then
  CT_PCT=$(( (CT_COUNT * 100) / CT_MAX ))
  echo "usage: ${CT_COUNT}/${CT_MAX} (${CT_PCT}%)"
else
  CT_PCT=0
  echo "usage: not available"
fi
echo "drops in logs: ${CT_DROPS}"

echo
sec "[OOM]"
echo "kernel OOM lines: ${OOM_LINES}"

echo
sec "[TOP RSS]"
echo "$TOP_RSS"
echo

hr
sec "Recommendations:"
if [[ "$CT_DROPS" -gt 0 ]]; then
  crit "conntrack drops detected (${CT_DROPS}). Increase nf_conntrack_max and persist via /etc/sysctl.d/*.conf"
else
  ok "no conntrack drops"
fi

if [[ -n "${CT_COUNT:-}" && -n "${CT_MAX:-}" && "${CT_MAX:-0}" -gt 0 ]]; then
  if [[ "$CT_PCT" -ge "$CT_USAGE_WARN_PCT" ]]; then
    warn "conntrack usage high (${CT_PCT}%). Consider increasing nf_conntrack_max."
  fi
fi

if [[ "$OOM_LINES" -gt 0 ]]; then
  crit "OOM activity detected (${OOM_LINES}). Add/expand swap, remove extra services, consider memory limits."
else
  ok "no OOM activity"
fi

if [[ "$SWAP_TOTAL_MB" -eq 0 ]]; then
  if [[ "$MEM_TOTAL_MB" -le 2048 ]]; then
    warn "swap is missing on ${MEM_TOTAL_MB}MB RAM host. Recommend 1–2GB swapfile."
  else
    ok "swap missing, but RAM >= 2GB (optional)"
  fi
else
  if [[ "$SWAP_USED_PCT" -ge "$SWAP_USED_WARN_PCT" ]]; then
    warn "swap usage high (${SWAP_USED_PCT}%). Expect lags; reduce memory pressure or increase RAM/swap."
  fi
fi

if [[ "$MEM_AVAIL_MB" -lt "$MEM_AVAIL_WARN_MB" ]]; then
  warn "low MemAvailable (${MEM_AVAIL_MB}MB). Risk of lags/OOM."
fi

if [[ "$DISK_USE_PCT" -ge "$DISK_USE_WARN_PCT" ]]; then
  warn "disk usage high (${DISK_USE_PCT}%). Clean logs/docker; consider journald limits."
fi

if [[ "$JOURNAL_MB" -ge "$JOURNAL_WARN_MB" && "$JOURNAL_MB" -ne 0 ]]; then
  warn "journald is large (~${JOURNAL_MB}MB). Consider vacuum + SystemMaxUse."
fi

hr
case "$STATE" in
  0) echo "${GREEN}${BOLD}STATUS: OK${RESET}";;
  1) echo "${YELLOW}${BOLD}STATUS: WARNING${RESET}";;
  2) echo "${RED}${BOLD}STATUS: CRITICAL${RESET}";;
esac

exit "$STATE"
