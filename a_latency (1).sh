#!/bin/sh
# a_latency.sh — Auto test latency YACD/OpenClash (robust JSON handling + update notifier)
# Log: /var/log/a_latency_exec.log

# ================== Versi Script (WAJIB DIPERTAHANKAN DI ATAS) ==================
VERSION="1.4.0"   # <- ganti saat rilis baru

# ================== Identitas Router ==================
HOSTNAME=$(ubus call system board | jsonfilter -e '@.hostname')

# ================== Logging ==================
LOGFILE="/var/log/a_latency_exec.log"
DATE_FMT() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "$(DATE_FMT) [INFO]  $*" >> "$LOGFILE"; logger -t a_latency "[INFO] $*"; }
log_error() { echo "$(DATE_FMT) [ERROR] $*" >> "$LOGFILE"; logger -t a_latency "[ERROR] $*"; }

# ================== Konfigurasi OpenClash API ==================
API_URL="http://127.0.0.1:9090"
SECRET="aira"
THRESH=300

# ================== Telegram (opsional—isi agar aktif) ==================
TG_TOKEN=$(uci get telegram.settings.bot_token 2>/dev/null)
TG_CHAT_ID=$(uci get telegram.settings.group_id 2>/dev/null)
TG_THREAD_ID="51869"

# ================== Skip daftar proxy ini ==================
SKIP_REGEX="^(DIRECT|REJECT|GLOBAL)$"

# ================== State anti-spam notifikasi ==================
STATE_DIR="/var/run/openclash-latency"
mkdir -p "$STATE_DIR" 2>/dev/null

# ================== Konfigurasi Update Checker ==================
# WAJIB: arahkan ke raw path file script ini di GitHub Anda.
# Contoh: https://raw.githubusercontent.com/<user>/<repo>/<branch>/a_latency.sh
GITHUB_RAW_URL="https://raw.githubusercontent.com/USER/REPO/BRANCH/a_latency.sh"
# Opsional: URL repo/commit log untuk referensi di notifikasi
GITHUB_REPO_URL="https://github.com/USER/REPO"
# Lokasi penyimpanan file download calon update
NEW_FILE_PATH="/usr/local/bin/a_latency.sh.new"
# Flag file: penanda ada update
UPDATE_FLAG_FILE="/etc/a_latency_update_available"

# ================== Cek Dependensi ==================
for cmd in curl jq logger; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Command '$cmd' not found. Install with: opkg install $cmd"
    exit 1
  fi
done
log_info "Dependencies OK."

# ================== Helper: Telegram ==================
tg_send() {
  [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return 0
  MSG="$1"
  API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
  if [ -n "$TG_THREAD_ID" ]; then
    curl -s -X POST "$API" \
      -d chat_id="$TG_CHAT_ID" \
      -d message_thread_id="$TG_THREAD_ID" \
      --data-urlencode "text=$MSG" >/dev/null 2>&1
  else
    curl -s -X POST "$API" \
      -d chat_id="$TG_CHAT_ID" \
      --data-urlencode "text=$MSG" >/dev/null 2>&1
  fi
}

# ================== Helper: bandingkan versi semver (x.y.z) ==================
# return 0 jika $1 < $2 (butuh update), 1 jika sebaliknya
ver_lt() {
  # normalisasi jadi tiga segmen
  A=$(printf "%s" "$1" | awk -F. '{printf("%d.%d.%d", $1,$2,$3)}')
  B=$(printf "%s" "$2" | awk -F. '{printf("%d.%d.%d", $1,$2,$3)}')
  [ "$A" = "$B" ] && return 1
  # bandingkan per segmen
  IFS=.; set -- $A; a1=$1; a2=$2; a3=$3
  IFS=.; set -- $B; b1=$1; b2=$2; b3=$3
  if [ "$a1" -lt "$b1" ]; then return 0; fi
  if [ "$a1" -gt "$b1" ]; then return 1; fi
  if [ "$a2" -lt "$b2" ]; then return 0; fi
  if [ "$a2" -gt "$b2" ]; then return 1; fi
  if [ "$a3" -lt "$b3" ]; then return 0; fi
  return 1
}

# ================== Cek Update dari GitHub ==================
check_update() {
  [ -z "$GITHUB_RAW_URL" ] && return 0

  # Ambil header (maks 8KB) supaya ringan
  REMOTE_HEAD=$(curl -fsSL --max-time 8 "$GITHUB_RAW_URL" | sed -n '1,80p')
  if [ -z "$REMOTE_HEAD" ]; then
    log_error "Gagal cek update (tidak bisa ambil raw GitHub)."
    return 1
  fi

  REMOTE_VERSION=$(printf "%s" "$REMOTE_HEAD" | grep -E '^VERSION="' | head -n1 | sed -E 's/^VERSION="([^"]+)".*$/\1/')
  if [ -z "$REMOTE_VERSION" ]; then
    # fallback: cari di seluruh file
    REMOTE_VERSION=$(curl -fsSL --max-time 12 "$GITHUB_RAW_URL" | grep -E '^VERSION="' | head -n1 | sed -E 's/^VERSION="([^"]+)".*$/\1/')
  fi

  if [ -z "$REMOTE_VERSION" ]; then
    log_error "Cek update: tidak menemukan VERSION pada file remote."
    return 1
  fi

  if ver_lt "$VERSION" "$REMOTE_VERSION"; then
    # Ada versi baru
    log_info "Update tersedia: local=$VERSION < remote=$REMOTE_VERSION"
    # Unduh calon update
    if curl -fsSL --max-time 20 "$GITHUB_RAW_URL" -o "$NEW_FILE_PATH"; then
      chmod +x "$NEW_FILE_PATH"
      echo "UPDATE_AVAILABLE=$REMOTE_VERSION $(DATE_FMT)" > "$UPDATE_FLAG_FILE"
      log_info "File update disimpan: $NEW_FILE_PATH (v$REMOTE_VERSION). Flag: $UPDATE_FLAG_FILE"

      tg_send "🔔 *Update a_latency.sh tersedia*\nRouter: $HOSTNAME\nVersi saat ini: $VERSION\nVersi baru: $REMOTE_VERSION\nFile baru: $NEW_FILE_PATH\nRepo: $GITHUB_REPO_URL\n\nJalankan untuk update:\nmv $NEW_FILE_PATH /usr/local/bin/a_latency.sh && chmod +x /usr/local/bin/a_latency.sh"
    else
      log_error "Gagal mengunduh file update dari GitHub."
      tg_send "⚠️ Gagal unduh update a_latency.sh dari GitHub. Coba ulangi nanti.\nRepo: $GITHUB_REPO_URL"
    fi
  else
    # Tidak ada update
    [ -f "$UPDATE_FLAG_FILE" ] && rm -f "$UPDATE_FLAG_FILE"
    log_info "Tidak ada update. Versi lokal ($VERSION) sudah terbaru (remote=$REMOTE_VERSION)."
  fi
}

# ================== Jalankan cek update (sebelum tes latency) ==================
check_update

# ================== Step 1: Cek API reachable ==================
RESP=$(curl -s -H "Authorization: Bearer $SECRET" "$API_URL/version")
if [ -z "$RESP" ]; then
  log_error "Cannot reach $API_URL/version (no response)."
  exit 1
else
  VER=$(echo "$RESP" | jq -r '.version? // . // empty' 2>/dev/null)
  log_info "API reachable. Version: ${VER:-unknown}"
fi

# ================== Step 2: Ambil daftar proxies ==================
PROXIES_JSON=$(curl -s -H "Authorization: Bearer $SECRET" "$API_URL/proxies")
if ! printf '%s' "$PROXIES_JSON" | jq -e 'has("proxies") and (.proxies|type=="object")' >/dev/null 2>&1; then
  log_error "Invalid JSON from /proxies. Raw: $(echo "$PROXIES_JSON" | tr '\n' ' ' | head -c 200)"
  exit 1
fi
COUNT=$(echo "$PROXIES_JSON" | jq '.proxies | keys | length')
log_info "Proxy list OK. Found $COUNT proxies."

# ================== Helper: ambil delay saat ini (robust) ==================
get_current_delay() {
  DETAIL_JSON="$1"
  T=$(printf '%s' "$DETAIL_JSON" | jq -r 'type' 2>/dev/null)
  case "$T" in
    object)
      printf '%s' "$DETAIL_JSON" | jq -r '
        if (.history|type=="array" and (.history|length)>0) then
          (.history | max_by(.time).delay // empty)
        else
          (.delay // empty)
        end
      ' 2>/dev/null
      ;;
    array)
      printf '%s' "$DETAIL_JSON" | jq -r '
        if length>0 then (max_by(.time).delay // empty) else empty end
      ' 2>/dev/null
      ;;
    *)
      echo ""
      ;;
  esac
}

# ================== Step 3: Loop & conditional test ==================
for NAME in $(echo "$PROXIES_JSON" | jq -r '.proxies | keys[]'); do
  if echo "$NAME" | grep -Eq "$SKIP_REGEX"; then
    log_info "Skip $NAME"
    echo "OK" > "$STATE_DIR/$(echo "$NAME" | tr '/ ' '__').state"
    continue
  fi

  ENCODED=$(printf '%s' "$NAME" | jq -sRr @uri)
  DETAIL=$(curl -s -H "Authorization: Bearer $SECRET" "$API_URL/proxies/$ENCODED" 2>/dev/null)
  CUR_DELAY="$(get_current_delay "$DETAIL")"

  CUR_NUM=1
  case "$CUR_DELAY" in ''|null|*[!0-9]*) CUR_NUM=0 ;; esac

  ACTION="skip"
  REASON=""
  EFFECTIVE_DELAY=""

  if [ "$CUR_NUM" -eq 0 ]; then
    ACTION="test"
    TYP=$(printf '%s' "$DETAIL" | jq -r 'type' 2>/dev/null)
    REASON="no ping (detail-type=${TYP:-unknown})"
  else
    if [ "$CUR_DELAY" -ge "$THRESH" ]; then
      ACTION="test"
      REASON="high ping (${CUR_DELAY}ms ≥ ${THRESH}ms)"
    else
      ACTION="skip"
      REASON="normal ping (${CUR_DELAY}ms < ${THRESH}ms)"
      EFFECTIVE_DELAY="$CUR_DELAY"
    fi
  fi

  if [ "$ACTION" = "skip" ]; then
    log_info "$NAME: $REASON, skip refresh"
    echo "OK" > "$STATE_DIR/$(echo "$NAME" | tr '/ ' '__').state"
    continue
  fi

  RESULT=$(curl -s -H "Authorization: Bearer $SECRET" \
    "$API_URL/proxies/$ENCODED/delay?timeout=5000&url=https://www.google.com/generate_204")

  if echo "$RESULT" | jq -e 'has("delay") or has("result")' >/dev/null 2>&1; then
    NEW_DELAY=$(echo "$RESULT" | jq -r '.delay? // .result? // empty')
    case "$NEW_DELAY" in
      ''|null|*[!0-9]*)
        if [ "$CUR_NUM" -eq 1 ]; then
          EFFECTIVE_DELAY="$CUR_DELAY"
        else
          EFFECTIVE_DELAY=""
        fi
        ;;
      *)
        EFFECTIVE_DELAY="$NEW_DELAY"
        ;;
    esac
    log_info "Latency : $NAME = ${EFFECTIVE_DELAY:-N/A}ms "
  else
    log_error "Latency test failed for $NAME. Response: $RESULT"
    EFFECTIVE_DELAY="$CUR_DELAY"
  fi

  STATE_FILE="$STATE_DIR/$(echo "$NAME" | tr '/ ' '__').state"
  PREV_STATE="OK"
  [ -f "$STATE_FILE" ] && PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null)

  if [ -n "$EFFECTIVE_DELAY" ] && [ "$EFFECTIVE_DELAY" -ge "$THRESH" ] 2>/dev/null; then
    if [ "$PREV_STATE" != "HIGH" ]; then
      tg_send "⚠️ $(DATE_FMT)
🔸Router: $HOSTNAME
🔸Proxy: $NAME
🔸Latency High : ${EFFECTIVE_DELAY} ms"
      echo "HIGH" > "$STATE_FILE"
      log_info "Notify HIGH sent for $NAME (${EFFECTIVE_DELAY}ms)"
    else
      log_info "$NAME remains HIGH (${EFFECTIVE_DELAY}ms)"
    fi
  else
    if [ "$PREV_STATE" = "HIGH" ] && [ -n "$EFFECTIVE_DELAY" ]; then
      tg_send "✅ $(DATE_FMT)
🔹Router: $HOSTNAME
🔹Proxy: $NAME kembali normal
🔹Latency: ${EFFECTIVE_DELAY} ms"
      log_info "Notify RECOVERY sent for $NAME (${EFFECTIVE_DELAY}ms)"
    fi
    echo "OK" > "$STATE_FILE"
  fi
done

log_info "Script executed successfully."
exit 0
