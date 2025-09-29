# Dockerfile
FROM alpine:3.20

# coreutils -> fractional sleep; tini -> clean PID 1
RUN apk add --no-cache bash curl ca-certificates tini coreutils

ENV XDG_STATE_HOME=/state
WORKDIR /app

RUN set -eux; cat > /app/ngwatch.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE="https://www.newgrounds.com/portal/view"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/ngwatch.state"
mkdir -p "$(dirname "$STATE_FILE")"

# --- Config (env overrides supported) ---
: "${START_ID:=999000}"
: "${STOP_AT:=}"
: "${SEED_ID:=${STOP_AT:-$START_ID}}"
: "${INTERVAL:=30}"
: "${THROTTLE:=0.2}"
: "${CURL_TIMEOUT:=12}"
: "${RETRIES:=3}"
: "${UA:=NG-FrontierWatcher/1.2 (+set-your-contact)}"

# Notifications
: "${NOTIFY_EVERY:=2}"
: "${SWITCH_AT_LEFT:=15}"
: "${ALWAYS_PER_POST:=0}"

# Frontier scan
: "${ADV_WINDOW:=200}"
: "${GAP_BUDGET:=4}"
: "${FORCE_RESEED:=0}"

# Logging
: "${POLL_LOG:=1}"
: "${PROBE_LOG:=0}"

ts() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "%s %s\n" "$(ts)" "$*"; }

classify_page() {
  local html="$1"
  if grep -q 'class="fatal-error"' <<<"$html"; then echo "missing"; return; fi
  if grep -qi 'Project not found or invalid' <<<"$html"; then echo "missing"; return; fi
  if grep -q '<meta property="og:title"' <<<"$html"; then echo "exists"; return; fi
  if grep -q 'data-share-url=' <<<"$html"; then echo "exists"; return; fi
  echo "inconclusive"
}

probe_id() {
  local id="$1"
  local attempt=1 html cls
  while (( attempt <= RETRIES )); do
    html="$(curl -sSL --max-time "$CURL_TIMEOUT" \
           -H "User-Agent: $UA" \
           -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
           -H "Accept-Language: en-US,en;q=0.9" \
           "$BASE/$id" || true)"
    cls="$(classify_page "$html")"
    if (( PROBE_LOG == 1 )); then log "🔎 probe id=$id attempt=$attempt -> $cls"; fi
    if [[ "$cls" != "inconclusive" ]]; then
      echo "$cls"; return 0
    fi
    sleep "$THROTTLE"
    attempt=$(( attempt + 1 ))
  done
  echo "inconclusive"
}

exists_strict() {
  local id="$1" cls
  cls="$(probe_id "$id")"
  if [[ "$cls" == "exists" ]]; then return 0; fi
  if [[ "$cls" == "missing" ]]; then return 1; fi
  sleep "$THROTTLE"
  [[ "$(probe_id "$id")" == "exists" ]]
}

# ✅ FIXED: declare variables first; assign after so $base exists under set -u
advance_window() {
  local base="$1"
  local i
  local best
  local miss=0

  best="$base"
  for (( i=base+1; i<=base+ADV_WINDOW; i++ )); do
    if exists_strict "$i"; then
      best="$i"; miss=0
    else
      miss=$(( miss + 1 ))
      if (( miss > GAP_BUDGET )); then
        break
      fi
    fi
    sleep "$THROTTLE"
  done
  echo "$best"
}

find_frontier() {
  local seed="$SEED_ID"
  (( 10#$seed < 1 )) && seed=1

  if exists_strict "$seed"; then
    local lo="$seed" hi=$(( seed + 1 )) step=1 miss=0 mid
    while :; do
      if exists_strict "$hi"; then
        lo="$hi"; step=$(( step * 2 )); hi=$(( hi + step )); miss=0
      else
        miss=$(( miss + 1 ))
        if (( miss > GAP_BUDGET )); then break; fi
        hi=$(( hi + 1 ))
      fi
      sleep "$THROTTLE"
    done
    while (( lo + 1 < hi )); do
      mid=$(( (lo + hi) / 2 ))
      if exists_strict "$mid"; then lo="$mid"; else hi="$mid"; fi
      sleep "$THROTTLE"
    done
    echo "$lo"
  else
    local hi="$seed" step=1 lo=$(( seed - 1 )) mid
    while (( lo > 0 )) && ! exists_strict "$lo"; do
      step=$(( step * 2 )); lo=$(( seed - step )); (( lo < 1 )) && lo=1
      sleep "$THROTTLE"
    done
    if (( lo < 1 )) || ! exists_strict "$lo"; then echo 0; return; fi
    while (( lo + 1 < hi )); do
      mid=$(( (lo + hi) / 2 ))
      if exists_strict "$mid"; then lo="$mid"; else hi="$mid"; fi
      sleep "$THROTTLE"
    done
    echo "$lo"
  fi
}

notify_for_id() {
  local id="$1"
  if [[ -n "${STOP_AT:-}" ]]; then
    local left=$(( STOP_AT - id )); (( left < 0 )) && left=0
    if (( ALWAYS_PER_POST == 1 )) || (( left <= SWITCH_AT_LEFT )); then
      log "🔔 ID $id — ${left} left until $STOP_AT"; return
    fi
    (( id % NOTIFY_EVERY == 0 )) && log "🎉 Reached ID $id — ${left} left to $STOP_AT"
  else
    if (( ALWAYS_PER_POST == 1 )); then
      log "🔔 ID $id"
    else
      (( id % NOTIFY_EVERY == 0 )) && log "🎉 Reached ID $id"
    fi
  fi
}

# ---- Boot ----
last="${START_ID}"
if [[ -f "$STATE_FILE" && "${FORCE_RESEED}" != "1" ]]; then
  last="$(cat "$STATE_FILE" 2>/dev/null || echo "$START_ID")"
fi

if ! exists_strict "$last"; then
  log "Boot: saved last=$last invalid; discovering frontier from SEED_ID=$SEED_ID…"
  last="$(find_frontier)"
else
  log "Boot: saved last=$last valid; advancing up to +$ADV_WINDOW to confirm frontier…"
  last="$(advance_window "$last")"
fi
printf '%s' "$last" > "$STATE_FILE"
log "✅ Frontier confirmed at ID $last. Polling only next ID every $INTERVAL s."

# ---- Watch loop ----
while :; do
  next=$(( last + 1 ))
  if (( POLL_LOG == 1 )); then
    log "⏳ Polling next=$next (last=$last)…"
  fi

  if exists_strict "$next"; then
    last="$next"; printf '%s' "$last" > "$STATE_FILE"; notify_for_id "$last"
    more=$(( last + 1 ))
    while exists_strict "$more"; do
      last="$more"; printf '%s' "$last" > "$STATE_FILE"; notify_for_id "$last"
      more=$(( more + 1 )); sleep "$THROTTLE"
    done
  else
    if (( POLL_LOG == 1 )); then
      log "🚧 $next not up yet; sleeping ${INTERVAL}s"
    fi
    sleep "$INTERVAL"
  fi

  if [[ -n "${STOP_AT:-}" ]] && (( last >= STOP_AT )); then
    log "🥳 Hit $STOP_AT! Exiting."; exit 0
  fi
done
BASH

RUN chmod +x /app/ngwatch.sh
VOLUME ["/state"]
ENTRYPOINT ["/sbin/tini","--"]
CMD ["/app/ngwatch.sh"]
