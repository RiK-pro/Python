#!/usr/bin/env bash
set -euo pipefail

SINCE="${1:-24 hours ago}"

CT_USAGE_WARN_PCT=80
MEM_AVAIL_WARN_MB=120
DISK_USE_WARN_PCT=85
JOURNAL_WARN_MB=800
SWAP_USED_WARN_PCT=70

# State: 0 OK, 1 WARN, 2 CRIT (Nagios-style exit codes) :contentReference[oaicite:0]{index=0}
STATE=0
warn(){ echo "WARN: $*"; STATE=$(( STATE<1 ? 1 : STATE )); }
crit(){ echo "CRIT: $*"; STATE=2; }

hr(){ echo "------------------------------------------------------------"; }

# Helpers
to_int(){ awk '{print int($1)}'; }

# ===== Collect =====
# conntrack current usage
CT_COUNT="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true)"
CT_MAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true)"

# conntrack drops in last period
CT_DROPS="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null \
  | grep -Ei "nf_conntrack:.*table full|dropping packet" | wc -l | to_int || true)"

# OOM in last period
OOM_LINES="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null \
  | grep -Eai "Out of memory: Killed process|oom-kill|invoked oom-killer" | wc -l | to_int || true)"

# memory (current)
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_AVAIL_MB="$(( MEM_AVAIL_KB / 1024 ))"
MEM_TOTAL_MB="$(( MEM_TOTAL_KB / 1024 ))"

# swap (current)
SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"
SWAP_USED_KB="$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))"
SWAP_TOTAL_MB="$(( SWAP_TOTAL_KB / 1024 ))"
SWAP_USED_MB="$(( SWAP_USED_KB / 1024 ))"
SWAP_USED_PCT=0
if [[ "$SWAP_TOTAL_KB" -gt 0 ]]; then
  SWAP_USED_PCT="$(( (SWAP_USED_KB * 100) / SWAP_TOTAL_KB ))"
fi

# disk /
DISK_USE_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}' | to_int)"
DISK_AVAIL="$(df -hP / | awk 'NR==2 {print $4}')"
DISK_USED="$(df -hP / | awk 'NR==2 {print $3}')"
DISK_SIZE="$(df -hP / | awk 'NR==2 {print $2}')"

# journald usage (current)
JOURNAL_LINE="$(journalctl --disk-usage 2>/dev/null || true)"
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

# ===== Report =====
hr
echo "VPN Node Healthcheck (since: $SINCE)"
hr

echo "[MEM]  total=${MEM_TOTAL_MB}MB  available=${MEM_AVAIL_MB}MB"
echo "[SWAP] total=${SWAP_TOTAL_MB}MB  used=${SWAP_USED_MB}MB  (${SWAP_USED_PCT}%)"
echo "[DISK] / ${DISK_USED}/${DISK_SIZE} used, ${DISK_AVAIL} avail, ${DISK_USE_PCT}% used"
echo "[JOURNAL] ${JOURNAL_LINE:-unknown} (~${JOURNAL_MB}MB)"
echo

echo "[CONNTRACK]"
if [[ -n "${CT_COUNT:-}" && -n "${CT_MAX:-}" ]]; then
  CT_PCT=$(( (CT_COUNT * 100) / CT_MAX ))
  echo "  usage: ${CT_COUNT}/${CT_MAX} (${CT_PCT}%)"  # nf_conntrack_max — лимит записей :contentReference[oaicite:1]{index=1}
else
  echo "  usage: not available"
  CT_PCT=0
fi
echo "  drops in logs: ${CT_DROPS}"
echo

echo "[OOM] kernel OOM lines: ${OOM_LINES}"
echo

echo "[TOP RSS]"
echo "$TOP_RSS"
echo

# ===== Recommendations / State =====
hr
echo "Recommendations:"
if [[ "$CT_DROPS" -gt 0 ]]; then
  crit "conntrack drops detected ($CT_DROPS). Increase nf_conntrack_max and persist via /etc/sysctl.d/*.conf"
else
  echo "OK: no conntrack drops"
fi

if [[ -n "${CT_COUNT:-}" && -n "${CT_MAX:-}" && "${CT_MAX:-0}" -gt 0 ]]; then
  if [[ "$CT_PCT" -ge "$CT_USAGE_WARN_PCT" ]]; then
    warn "conntrack usage high (${CT_PCT}%). Consider increasing nf_conntrack_max."
  fi
fi

if [[ "$OOM_LINES" -gt 0 ]]; then
  crit "OOM activity detected ($OOM_LINES). Add/expand swap, remove extra services, consider memory limits."
else
  echo "OK: no OOM activity"
fi

if [[ "$SWAP_TOTAL_MB" -eq 0 ]]; then
  # На маленьких VPS (<=2GB) отсутствие swap часто приводит к OOM-пикам
  if [[ "$MEM_TOTAL_MB" -le 2048 ]]; then
    warn "swap is missing on ${MEM_TOTAL_MB}MB RAM host. Recommend 1–2GB swapfile."
  else
    echo "OK: swap missing, but RAM is >= 2GB (optional)."
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
  warn "disk usage high (${DISK_USE_PCT}%). Clean logs/docker; consider journald limits (SystemMaxUse/RuntimeMaxUse)."  # journald limits :contentReference[oaicite:2]{index=2}
fi

if [[ "$JOURNAL_MB" -ge "$JOURNAL_WARN_MB" && "$JOURNAL_MB" -ne 0 ]]; then
  warn "journald is large (~${JOURNAL_MB}MB). Consider vacuum + SystemMaxUse."
fi

hr
case "$STATE" in
  0) echo "STATUS: OK";;
  1) echo "STATUS: WARNING";;
  2) echo "STATUS: CRITICAL";;
esac
exit "$STATE"
