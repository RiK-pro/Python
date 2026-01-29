# ===== Smarter recommendations (RU) =====

recommend_swap_mb() {
  # Простое правило именно под VPS/ноды:
  # <=1GB RAM -> 1024–2048MB swap (чаще спасает от OOM/пиков)
  # 1–4GB RAM -> swap примерно = RAM
  # >4GB -> 2–4GB обычно достаточно
  # (ориентир по типовым гайдам для VPS) :contentReference[oaicite:3]{index=3}
  local ram_mb="$1"
  if   (( ram_mb <= 1024 )); then echo 2048
  elif (( ram_mb <= 4096 )); then echo "$ram_mb"
  else echo 4096
  fi
}

# Порог “дропы были недавно”
CT_DROPS_RECENT="$(journalctl -k --since "10 minutes ago" --no-pager 2>/dev/null \
  | grep -Ei 'nf_conntrack:.*table full|dropping packet' | wc -l | to_int || echo 0)"

SWAP_RECOMMENDED_MB="$(recommend_swap_mb "$MEM_TOTAL_MB")"

hr
sec "Рекомендации:"

# --- Conntrack ---
if [[ "$CT_DROPS" -gt 0 ]]; then
  crit "За последние ${SINCE}: обнаружены conntrack-дропы (${CT_DROPS}). Это обычно = у пользователей рвутся/лагают соединения."
  echo "  Что делать: увеличить net.netfilter.nf_conntrack_max и закрепить в /etc/sysctl.d/*.conf." \
    "Проверяй: count/max и наличие новых 'table full' в kernel-логе." :contentReference[oaicite:4]{index=4}
else
  ok "За последние ${SINCE}: conntrack-дропов не найдено."
fi

if [[ "${CT_DROPS_RECENT:-0}" -gt 0 ]]; then
  crit "Прямо сейчас (10 мин): conntrack-дропы идут (${CT_DROPS_RECENT}) — проблема активна."
else
  ok "Прямо сейчас (10 мин): conntrack-дропов нет."
fi

if [[ -n "${CT_COUNT:-}" && -n "${CT_MAX:-}" && "${CT_MAX:-0}" -gt 0 ]]; then
  if [[ "$CT_PCT" -ge 90 ]]; then
    crit "Conntrack почти забит (${CT_PCT}%). Срочно поднимать nf_conntrack_max."
  elif [[ "$CT_PCT" -ge "$CT_USAGE_WARN_PCT" ]]; then
    warn "Conntrack высокий (${CT_PCT}%). Лучше поднять nf_conntrack_max с запасом."
  else
    ok "Conntrack сейчас норм (${CT_PCT}%)."
  fi
fi

# --- OOM ---
if [[ "$OOM_LINES" -gt 0 ]]; then
  crit "За последние ${SINCE}: были события OOM (${OOM_LINES}). Это = кого-то убивали по памяти."
  echo "  Что делать: добавить/увеличить swap, убрать лишнее (например панели), проверить топ по RSS."
else
  ok "За последние ${SINCE}: OOM-событий не найдено."
fi

# --- RAM + Swap состояние ---
if [[ "$MEM_AVAIL_MB" -lt "$MEM_AVAIL_WARN_MB" ]]; then
  warn "Мало доступной памяти: MemAvailable=${MEM_AVAIL_MB}MB. Риск лагов/OOM при пиках."
else
  ok "MemAvailable=${MEM_AVAIL_MB}MB — терпимо."
fi

if [[ "$SWAP_TOTAL_MB" -eq 0 ]]; then
  warn "Swap отсутствует. На маленьких VPS это часто приводит к OOM-пикам."
  echo "  Рекомендация: сделать swap ${SWAP_RECOMMENDED_MB}MB (ориентир под RAM=${MEM_TOTAL_MB}MB)." :contentReference[oaicite:5]{index=5}
else
  ok "Swap есть: total=${SWAP_TOTAL_MB}MB."
  if [[ "$SWAP_TOTAL_MB" -lt "$SWAP_RECOMMENDED_MB" ]]; then
    warn "Swap есть, но маловат: ${SWAP_TOTAL_MB}MB. Рекомендую ~${SWAP_RECOMMENDED_MB}MB под RAM=${MEM_TOTAL_MB}MB." :contentReference[oaicite:6]{index=6}
  fi
  if [[ "$SWAP_USED_PCT" -ge "$SWAP_USED_WARN_PCT" ]]; then
    warn "Swap сильно используется (${SWAP_USED_PCT}%). Возможны лаги. Стоит разгрузить память или увеличить RAM/swap."
  else
    ok "Swap usage=${SWAP_USED_PCT}% — норм."
  fi
fi

# --- Disk / Journald ---
if [[ "$DISK_USE_PCT" -ge "$DISK_USE_WARN_PCT" ]]; then
  warn "Диск почти забит (${DISK_USE_PCT}%). Логи/контейнеры/кэш — кандидаты на чистку."
else
  ok "Диск по /: ${DISK_USE_PCT}% — норм."
fi

if [[ "$JOURNAL_MB" -ge "$JOURNAL_WARN_MB" && "$JOURNAL_MB" -ne 0 ]]; then
  warn "Journald большой (~${JOURNAL_MB}MB). Можно ужать: vacuum и лимиты SystemMaxUse/RuntimeMaxUse." :contentReference[oaicite:7]{index=7}
  echo "  Быстро: sudo journalctl --vacuum-size=200M" :contentReference[oaicite:8]{index=8}
else
  ok "Journald размер ок (~${JOURNAL_MB}MB)."
fi
