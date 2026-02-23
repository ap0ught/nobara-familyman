#!/usr/bin/env bash
# setup.sh — Idempotent NUC HTPC installer for Nobara (voice assistant + Steam shell + Kodi)
# Usage:  sudo ./setup.sh [--event 'button/power PBTN 00000080 00000000']
#                         [--model mistral]  [--record-seconds 5]
#                         [--mic-device hw:0,0] [--speaker-device hw:0,0]
#                         [--tv-width 3840] [--tv-height 2160]
#                         [--render-width 1920] [--render-height 1080]
#                         [--framerate 60]
#                         [--kodi-host localhost] [--kodi-port 8080]
#                         [--kodi-user kodi] [--kodi-pass kodi]
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
HTPC_USER="familyman"          # main HTPC user — created if absent
MODEL_NAME="${MODEL_NAME:-mistral}"
RECORD_SECONDS="${RECORD_SECONDS:-5}"
MIC_DEVICE="${MIC_DEVICE:-default}"
SPEAKER_DEVICE="${SPEAKER_DEVICE:-default}"
ACPI_EVENT_MATCH="button/power.*"
LOGFILE="/var/log/nuc-voice-assistant.log"
VOICE_DIR=""          # resolved after we know the real user
PIPER_VOICE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
PIPER_JSON_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
# HTPC / TV output defaults (Phase 1 + 4)
TV_WIDTH="${TV_WIDTH:-3840}"
TV_HEIGHT="${TV_HEIGHT:-2160}"
RENDER_WIDTH="${RENDER_WIDTH:-1920}"
RENDER_HEIGHT="${RENDER_HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-60}"
# Kodi JSON-RPC defaults (Phase 2 + 3)
KODI_HOST="${KODI_HOST:-localhost}"
KODI_PORT="${KODI_PORT:-8080}"
KODI_USER="${KODI_USER:-kodi}"
KODI_PASS="${KODI_PASS:-kodi}"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)          ACPI_EVENT_MATCH="$2"; shift 2 ;;
    --model)          MODEL_NAME="$2"; shift 2 ;;
    --record-seconds) RECORD_SECONDS="$2"; shift 2 ;;
    --mic-device)     MIC_DEVICE="$2"; shift 2 ;;
    --speaker-device) SPEAKER_DEVICE="$2"; shift 2 ;;
    --tv-width)       TV_WIDTH="$2"; shift 2 ;;
    --tv-height)      TV_HEIGHT="$2"; shift 2 ;;
    --render-width)   RENDER_WIDTH="$2"; shift 2 ;;
    --render-height)  RENDER_HEIGHT="$2"; shift 2 ;;
    --framerate)      FRAMERATE="$2"; shift 2 ;;
    --kodi-host)      KODI_HOST="$2"; shift 2 ;;
    --kodi-port)      KODI_PORT="$2"; shift 2 ;;
    --kodi-user)      KODI_USER="$2"; shift 2 ;;
    --kodi-pass)      KODI_PASS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Input validation ─────────────────────────────────────────────────────────
if ! [[ "$RECORD_SECONDS" =~ ^[0-9]+$ ]] || [[ "$RECORD_SECONDS" -lt 1 ]] || [[ "$RECORD_SECONDS" -gt 300 ]]; then
  echo "Error: --record-seconds must be a positive integer between 1 and 300." >&2
  exit 1
fi
# Allow only safe characters for ALSA device names (alphanumeric, colon, comma, hyphen, dot)
if [[ "$MIC_DEVICE" != "default" ]] && ! [[ "$MIC_DEVICE" =~ ^[a-zA-Z0-9_:,.-]+$ ]]; then
  echo "Error: --mic-device contains invalid characters (allowed: a-z A-Z 0-9 _ : , . -)." >&2
  exit 1
fi
if [[ "$SPEAKER_DEVICE" != "default" ]] && ! [[ "$SPEAKER_DEVICE" =~ ^[a-zA-Z0-9_:,.-]+$ ]]; then
  echo "Error: --speaker-device contains invalid characters (allowed: a-z A-Z 0-9 _ : , . -)." >&2
  exit 1
fi
for _param_name in TV_WIDTH TV_HEIGHT RENDER_WIDTH RENDER_HEIGHT FRAMERATE; do
  _param_val="${!_param_name}"
  if ! [[ "$_param_val" =~ ^[0-9]+$ ]] || [[ "$_param_val" -lt 1 ]]; then
    echo "Error: --${_param_name//_/-} must be a positive integer." >&2
    exit 1
  fi
done
if ! [[ "$KODI_PORT" =~ ^[0-9]+$ ]] || [[ "$KODI_PORT" -lt 1 ]] || [[ "$KODI_PORT" -gt 65535 ]]; then
  echo "Error: --kodi-port must be an integer between 1 and 65535." >&2
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[setup] $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
  fi
}

# Determine the real (non-root) user who invoked sudo, preferring HTPC_USER
get_real_user() {
  # If the canonical HTPC user already exists, always use it
  if getent passwd "$HTPC_USER" &>/dev/null; then
    echo "$HTPC_USER"
  elif [[ -n "${SUDO_USER:-}" ]]; then
    echo "$SUDO_USER"
  else
    # Fallback: first non-root user with a home under /home
    getent passwd | awk -F: '$3>=1000 && $6~/^\/home/ {print $1; exit}'
  fi
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
require_root

# ─── Step 0: Ensure familyman user exists ────────────────────────────────────
log "=== Step 0: familyman user ==="

if ! getent passwd "$HTPC_USER" &>/dev/null; then
  useradd -m -c "Family HTPC user" -s /bin/bash "$HTPC_USER"
  ok "Created user $HTPC_USER"
else
  ok "User $HTPC_USER already exists"
fi

# Add to wheel (sudo) and audio groups if not already a member
for grp in wheel audio video; do
  if getent group "$grp" &>/dev/null && ! id -nG "$HTPC_USER" | grep -qw "$grp"; then
    usermod -aG "$grp" "$HTPC_USER"
    ok "Added $HTPC_USER to group $grp"
  fi
done

# Passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/familyman"
if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -q "^${HTPC_USER} " "$SUDOERS_FILE" 2>/dev/null; then
  echo "${HTPC_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
  ok "Passwordless sudo configured at $SUDOERS_FILE"
else
  ok "Passwordless sudo already configured"
fi

# Autologin — detect display manager
_configure_autologin() {
  local user="$1"

  # SDDM (KDE / Nobara default)
  if systemctl is-enabled --quiet sddm 2>/dev/null || [[ -d /etc/sddm.conf.d ]]; then
    install -d /etc/sddm.conf.d
    local sddm_conf="/etc/sddm.conf.d/autologin.conf"
    cat > "$sddm_conf" << SDDMEOF
[Autologin]
User=${user}
Session=plasma
SDDMEOF
    chmod 644 "$sddm_conf"
    ok "SDDM autologin configured ($sddm_conf)"
    return 0
  fi

  # GDM (fallback)
  if systemctl is-enabled --quiet gdm 2>/dev/null; then
    local gdm_conf="/etc/gdm/custom.conf"
    if [[ -f "$gdm_conf" ]]; then
      # Replace or insert AutomaticLogin* under [daemon]
      sed -i.bak \
        -e 's/^#\?AutomaticLoginEnable=.*/AutomaticLoginEnable=True/' \
        -e 's/^#\?AutomaticLogin=.*/AutomaticLogin='"${user}"'/' \
        "$gdm_conf"
      # Add if not present at all
      grep -q 'AutomaticLoginEnable' "$gdm_conf" || \
        sed -i '/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin='"${user}" "$gdm_conf"
      ok "GDM autologin configured ($gdm_conf)"
    else
      warn "GDM config not found at $gdm_conf; skipping autologin configuration."
    fi
    return 0
  fi

  warn "Neither SDDM nor GDM found; autologin not configured automatically."
  warn "Configure autologin for user '${user}' manually in your display manager settings."
}

_configure_autologin "$HTPC_USER"

REAL_USER="$(get_real_user)"
if [[ -z "$REAL_USER" ]]; then
  echo "Error: could not determine the real user." >&2
  exit 1
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
VOICE_DIR="$REAL_HOME/voice_assistant"

log "Installing for user: $REAL_USER (home: $REAL_HOME)"
log "Voice-assistant dir: $VOICE_DIR"
log "LLM model          : $MODEL_NAME"
log "Record seconds     : $RECORD_SECONDS"
log "ACPI event match   : $ACPI_EVENT_MATCH"
log "TV resolution      : ${TV_WIDTH}x${TV_HEIGHT} (render ${RENDER_WIDTH}x${RENDER_HEIGHT} @ ${FRAMERATE}fps)"
log "Kodi JSON-RPC      : http://${KODI_HOST}:${KODI_PORT}"

# ─── 1. System dependencies ───────────────────────────────────────────────────
log "=== Step 1: System dependencies ==="

PKGS=(
  acpid
  alsa-utils
  pipewire-utils
  python3
  python3-pip
  python3-virtualenv
  curl
  jq
  sox
  util-linux   # provides flock
)

# Check if piper is available as a distro package
PIPER_PKG=""
if dnf info piper &>/dev/null; then
  PIPER_PKG="piper"
  PKGS+=("piper")
fi

TO_INSTALL=()
for pkg in "${PKGS[@]}"; do
  if ! rpm -q "$pkg" &>/dev/null; then
    TO_INSTALL+=("$pkg")
  fi
done

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
  log "Installing: ${TO_INSTALL[*]}"
  dnf -y install "${TO_INSTALL[@]}"
else
  ok "All system packages already installed"
fi

# ─── 1b. Optional HTPC packages (Steam, Kodi, emulators) ─────────────────────
log "=== Step 1b: Optional HTPC packages ==="

HTPC_PKGS=(steam gamescope kodi dolphin-emu retroarch moonlight-qt)
HTPC_TO_INSTALL=()
for pkg in "${HTPC_PKGS[@]}"; do
  if rpm -q "$pkg" &>/dev/null; then
    ok "$pkg already installed"
  elif dnf info "$pkg" &>/dev/null 2>&1; then
    HTPC_TO_INSTALL+=("$pkg")
  else
    warn "Optional package '$pkg' not found in enabled repos; skipping. Enable RPMFusion or use Flatpak to install it manually."
  fi
done

if [[ ${#HTPC_TO_INSTALL[@]} -gt 0 ]]; then
  log "Installing optional HTPC packages: ${HTPC_TO_INSTALL[*]}"
  dnf -y install "${HTPC_TO_INSTALL[@]}" || warn "Some optional HTPC packages failed to install; continuing."
else
  ok "All optional HTPC packages handled"
fi

# ─── 2. Install & enable Ollama ───────────────────────────────────────────────
log "=== Step 2: Ollama ==="

if ! command -v ollama &>/dev/null; then
  log "Downloading and installing Ollama..."
  # NOTE: This pipes a remote script directly to sh as root — a well-known supply-chain
  # risk. If you prefer, install ollama from a trusted package source manually, then
  # re-run this script. See https://github.com/ollama/ollama for alternatives.
  curl -fsSL https://ollama.com/install.sh | sh
else
  ok "ollama already installed: $(ollama --version 2>&1 | head -1)"
fi

if ! systemctl is-enabled --quiet ollama 2>/dev/null; then
  systemctl enable --now ollama
  ok "ollama service enabled and started"
else
  systemctl start ollama 2>/dev/null || true
  ok "ollama service already enabled"
fi

# Give ollama a moment to start before pulling
sleep 2

log "Pulling model: $MODEL_NAME (this may take a while on first run)..."
if sudo -u "$REAL_USER" ollama list 2>/dev/null | awk -v target="${MODEL_NAME}" '
  NR>1 {
    name=$1; split(name, parts, ":"); base=parts[1]
    if (name==target || base==target) { found=1; exit }
  }
  END { exit !found }'; then
  ok "Model $MODEL_NAME already present"
else
  sudo -u "$REAL_USER" ollama pull "$MODEL_NAME" || warn "Failed to pull model $MODEL_NAME; will retry on first use"
fi

# ─── 3. faster-whisper Python venv ────────────────────────────────────────────
log "=== Step 3: faster-whisper venv ==="

VENV_DIR="$VOICE_DIR/venv"

install -d -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$VOICE_DIR"

if [[ ! -d "$VENV_DIR" ]]; then
  sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR"
  ok "Created venv at $VENV_DIR"
else
  ok "venv already exists"
fi

sudo -u "$REAL_USER" "$VENV_DIR/bin/pip" install --quiet --upgrade pip
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip" install --quiet faster-whisper soundfile
ok "faster-whisper installed in venv"

# Pre-download the Whisper "base" model so the assistant works fully offline
log "Pre-downloading Whisper 'base' model for offline use..."
sudo -u "$REAL_USER" "$VENV_DIR/bin/python3" -c "
from faster_whisper import WhisperModel
print('[setup] Initialising WhisperModel (downloads on first run)...')
WhisperModel('base', device='cpu', compute_type='int8')
print('[setup] Whisper base model ready.')
" || warn "Failed to pre-download Whisper model; it will be downloaded on first voice command."

# ─── 4. Piper binary & voice model ───────────────────────────────────────────
log "=== Step 4: Piper TTS ==="

PIPER_BIN=""
VOICES_DIR="$VOICE_DIR/voices"
install -d -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$VOICES_DIR"

if [[ -n "$PIPER_PKG" ]]; then
  PIPER_BIN="$(command -v piper 2>/dev/null || echo "")"
  ok "Using distro piper package: $PIPER_BIN"
fi

if [[ -z "$PIPER_BIN" ]]; then
  PIPER_BIN_DIR="$VOICE_DIR/bin"
  install -d -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$PIPER_BIN_DIR"
  PIPER_BIN="$PIPER_BIN_DIR/piper"
  if [[ ! -x "$PIPER_BIN" ]]; then
    log "Piper not available via DNF; downloading release binary..."
    ARCH="$(uname -m)"
    # Pin to a specific release to avoid pulling unverified 'latest' binaries.
    # Override PIPER_VERSION or PIPER_SHA256 before running to update/verify.
    PIPER_VERSION="${PIPER_VERSION:-2023.11.14-2}"
    PIPER_RELEASE_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_${ARCH}.tar.gz"
    TMP_PIPER="/tmp/piper_dl.tar.gz"
    curl -fsSL -o "$TMP_PIPER" "$PIPER_RELEASE_URL"
    # Optional SHA256 verification — set PIPER_SHA256 before running for full supply-chain safety
    if [[ -n "${PIPER_SHA256:-}" ]]; then
      echo "${PIPER_SHA256}  ${TMP_PIPER}" | sha256sum -c - || {
        rm -f "$TMP_PIPER"
        echo "Error: piper binary checksum mismatch. Aborting." >&2
        exit 1
      }
      ok "piper checksum verified"
    else
      warn "PIPER_SHA256 not set; skipping checksum verification. Set PIPER_SHA256=<sha256> before running for supply-chain safety."
    fi
    tar -xzf "$TMP_PIPER" -C "$PIPER_BIN_DIR" --strip-components=1
    chmod +x "$PIPER_BIN"
    chown "$REAL_USER:$(id -gn "$REAL_USER")" "$PIPER_BIN"
    rm -f "$TMP_PIPER"
    ok "piper binary installed at $PIPER_BIN"
  else
    ok "piper binary already at $PIPER_BIN"
  fi
fi

VOICE_ONNX="$VOICES_DIR/en_US-lessac-medium.onnx"
VOICE_JSON="$VOICES_DIR/en_US-lessac-medium.onnx.json"

if [[ ! -f "$VOICE_ONNX" ]]; then
  log "Downloading Piper voice model..."
  sudo -u "$REAL_USER" curl -fsSL -o "$VOICE_ONNX" "$PIPER_VOICE_URL"
  ok "Downloaded $VOICE_ONNX"
else
  ok "Voice model already present"
fi

if [[ ! -f "$VOICE_JSON" ]]; then
  sudo -u "$REAL_USER" curl -fsSL -o "$VOICE_JSON" "$PIPER_JSON_URL"
  ok "Downloaded $VOICE_JSON"
fi

# ─── 5. Create voice_trigger.sh + Python helpers ─────────────────────────────
log "=== Step 5: voice_trigger.sh ==="

# ── 5a. intent_detect.py ─────────────────────────────────────────────────────
INTENT_SCRIPT="$VOICE_DIR/intent_detect.py"
cat > "$INTENT_SCRIPT" << 'INTENT_PY_EOF'
#!/usr/bin/env python3
"""intent_detect.py — Classify a voice transcript into a structured JSON intent
using an Ollama LLM.  Called from voice_trigger.sh.

Usage: python3 intent_detect.py <transcript> <model_name> <out_json_path>
"""
import json
import re
import subprocess
import sys


def main() -> None:
    transcript = sys.argv[1]
    model      = sys.argv[2]
    out_path   = sys.argv[3]

    prompt = (
        "You are a smart-home media controller. Parse the voice command below "
        "and respond ONLY with a single valid JSON object — no markdown, no "
        "explanation.\n\n"
        "Voice command: " + json.dumps(transcript) + "\n\n"
        "Choose exactly ONE of these JSON responses:\n"
        '{"action":"play","query":"<title or show name>"}\n'
        '{"action":"pause"}\n'
        '{"action":"stop"}\n'
        '{"action":"resume"}\n'
        '{"action":"next"}\n'
        '{"action":"previous"}\n'
        '{"action":"volume","level":<integer 0-100>}\n'
        '{"action":"answer","response":"<concise answer in 1-2 sentences>"}\n\n'
        "JSON only:"
    )

    result = subprocess.run(
        ["ollama", "run", model, prompt],
        capture_output=True, text=True, timeout=30
    )
    text = result.stdout.strip()

    # Extract the first JSON object from the model response
    m = re.search(r"\{[^{}]*\}", text, re.DOTALL)
    if m:
        try:
            obj = json.loads(m.group(0))
            intent = json.dumps(obj)
        except json.JSONDecodeError:
            intent = json.dumps({"action": "answer",
                                 "response": text[:300] or "I could not understand that."})
    else:
        intent = json.dumps({"action": "answer",
                             "response": text[:300] if text else "I could not understand that."})

    with open(out_path, "w") as f:
        f.write(intent)


if __name__ == "__main__":
    main()
INTENT_PY_EOF

chown "$REAL_USER:$(id -gn "$REAL_USER")" "$INTENT_SCRIPT"
chmod 755 "$INTENT_SCRIPT"
ok "Created $INTENT_SCRIPT"

# ── 5b. kodi_search.py ───────────────────────────────────────────────────────
KODI_SEARCH_SCRIPT="$VOICE_DIR/kodi_search.py"
cat > "$KODI_SEARCH_SCRIPT" << 'KODI_SEARCH_PY_EOF'
#!/usr/bin/env python3
"""kodi_search.py — Search the Kodi library for a title and print a
Player.Open item parameter (JSON) if found, or an empty string if not.

Usage: python3 kodi_search.py <query> <kodi_jsonrpc_url> <user:pass>
  e.g. python3 kodi_search.py "Stargate Universe" \
           http://localhost:8080/jsonrpc kodi:kodi
"""
import base64
import json
import sys
import urllib.request


def kodi_call(url: str, auth: str, method: str, params: dict | None = None) -> dict:
    body = json.dumps({
        "jsonrpc": "2.0", "method": method,
        "params": params or {}, "id": 1,
    }).encode()
    token = base64.b64encode(auth.encode()).decode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Basic {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception:
        return {}


def main() -> None:
    query = sys.argv[1]
    url   = sys.argv[2]
    auth  = sys.argv[3]

    filt = {"filter": {"field": "title", "operator": "contains", "value": query},
            "limits": {"end": 5}}

    # 1. TV shows → episodes
    shows = (kodi_call(url, auth, "VideoLibrary.GetTVShows",
                       {**filt, "properties": ["title"]})
             .get("result", {}).get("tvshows", []))
    if shows:
        eps = (kodi_call(url, auth, "VideoLibrary.GetEpisodes", {
                   "tvshowid": shows[0]["tvshowid"],
                   "sort": {"order": "ascending", "method": "episode"},
                   "limits": {"end": 1},
                   "properties": ["title"],
               }).get("result", {}).get("episodes", []))
        if eps:
            print(json.dumps({"episodeid": eps[0]["episodeid"]}))
            return

    # 2. Movies
    movies = (kodi_call(url, auth, "VideoLibrary.GetMovies",
                        {**filt, "properties": ["title"]})
              .get("result", {}).get("movies", []))
    if movies:
        print(json.dumps({"movieid": movies[0]["movieid"]}))
        return

    # Nothing found
    print("")


if __name__ == "__main__":
    main()
KODI_SEARCH_PY_EOF

chown "$REAL_USER:$(id -gn "$REAL_USER")" "$KODI_SEARCH_SCRIPT"
chmod 755 "$KODI_SEARCH_SCRIPT"
ok "Created $KODI_SEARCH_SCRIPT"

# ── 5c. voice_trigger.sh ─────────────────────────────────────────────────────
TRIGGER_SCRIPT="$VOICE_DIR/voice_trigger.sh"

cat > "$TRIGGER_SCRIPT" << TRIGGER_EOF
#!/usr/bin/env bash
# voice_trigger.sh — STT → Intent → Kodi/TTS pipeline
# Invoked by ACPI event; runs as the real user via sudo -u in the ACPI action.
set -euo pipefail

MODEL_NAME="${MODEL_NAME}"
RECORD_SECONDS="${RECORD_SECONDS}"
MIC_DEVICE="${MIC_DEVICE}"
SPEAKER_DEVICE="${SPEAKER_DEVICE}"
LOGFILE="${LOGFILE}"
VOICE_DIR="${VOICE_DIR}"
VENV_DIR="${VOICE_DIR}/venv"
PIPER_BIN="${PIPER_BIN}"
VOICE_MODEL="${VOICES_DIR}/en_US-lessac-medium.onnx"
KODI_HOST="${KODI_HOST}"
KODI_PORT="${KODI_PORT}"
KODI_USER="${KODI_USER}"
KODI_PASS="${KODI_PASS}"

# Private temp directory — 700 so other users cannot read recorded audio/transcripts
TMP_DIR="\${VOICE_DIR}/tmp"
mkdir -p "\$TMP_DIR"
chmod 700 "\$TMP_DIR"
IN_WAV="\${TMP_DIR}/nuc_assistant_in.wav"
OUT_WAV="\${TMP_DIR}/nuc_assistant_out.wav"
TRANSCRIPT_FILE="\${TMP_DIR}/nuc_assistant_transcript.txt"
INTENT_FILE="\${TMP_DIR}/nuc_assistant_intent.json"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
logit() { echo "\$(ts) \$*" | tee -a "\$LOGFILE"; }

# Clean up temp files on exit (success or error)
cleanup() { rm -f "\$IN_WAV" "\$OUT_WAV" "\$TRANSCRIPT_FILE" "\$INTENT_FILE"; }
trap cleanup EXIT

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${VENV_DIR}/bin"

# Send a Kodi JSON-RPC request; prints response JSON (or {} on error)
kodi_rpc() {
  local method="\$1" params="\${2:-{}}"
  curl -sf --max-time 10 \
    -u "\${KODI_USER}:\${KODI_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"\${method}\",\"params\":\${params},\"id\":1}" \
    "http://\${KODI_HOST}:\${KODI_PORT}/jsonrpc" 2>>\$LOGFILE || echo "{}"
}

# Return active player ID, or empty string if nothing is playing
get_player_id() {
  kodi_rpc "Player.GetActivePlayers" "{}" | \
    "\${VENV_DIR}/bin/python3" -c \
    "import sys,json; pl=json.load(sys.stdin).get('result',[]); print(pl[0]['playerid'] if pl else '')" \
    2>/dev/null || echo ""
}

logit "[voice] Starting voice assistant pipeline"

# 1. Record audio
logit "[voice] Recording \${RECORD_SECONDS}s from device: \${MIC_DEVICE}"
if [[ "\$MIC_DEVICE" == "default" ]]; then
  /usr/bin/arecord -f S16_LE -r 16000 -c 1 -d "\$RECORD_SECONDS" "\$IN_WAV" 2>>\$LOGFILE
else
  /usr/bin/arecord -D "\$MIC_DEVICE" -f S16_LE -r 16000 -c 1 -d "\$RECORD_SECONDS" "\$IN_WAV" 2>>\$LOGFILE
fi

if [[ ! -s "\$IN_WAV" ]]; then
  logit "[voice] ERROR: recorded file is empty; aborting."
  exit 1
fi

# 2. Transcribe with faster-whisper
logit "[voice] Transcribing..."
"\${VENV_DIR}/bin/python3" - <<'PYEOF' "\$IN_WAV" "\$TRANSCRIPT_FILE"
import sys
try:
    from faster_whisper import WhisperModel
    audio_path  = sys.argv[1]
    output_path = sys.argv[2]
    model = WhisperModel("base", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(audio_path, beam_size=5)
    text = " ".join(seg.text.strip() for seg in segments)
    with open(output_path, "w") as f:
        f.write(text)
except Exception as exc:
    print(f"[voice] Transcription error: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF

TRANSCRIPT="\$(cat "\$TRANSCRIPT_FILE" 2>/dev/null || echo "")"
if [[ -z "\$TRANSCRIPT" ]]; then
  logit "[voice] Transcription empty; nothing to process."
  exit 0
fi
logit "[voice] Transcript: \$TRANSCRIPT"

# 3. Intent detection via Ollama
logit "[voice] Detecting intent (model: \$MODEL_NAME)..."
"\${VENV_DIR}/bin/python3" "\${VOICE_DIR}/intent_detect.py" \
  "\$TRANSCRIPT" "\$MODEL_NAME" "\$INTENT_FILE" 2>>\$LOGFILE || \
  echo '{"action":"answer","response":"I could not process that request."}' > "\$INTENT_FILE"

INTENT_JSON="\$(cat "\$INTENT_FILE" 2>/dev/null || echo '{"action":"answer","response":"I could not process that request."}')"
ACTION="\$("\${VENV_DIR}/bin/python3" -c \
  "import sys,json; print(json.loads(sys.argv[1]).get('action','answer'))" \
  "\$INTENT_JSON" 2>/dev/null || echo "answer")"
logit "[voice] Intent: \$ACTION"

# 4. Dispatch on intent
RESPONSE=""
case "\$ACTION" in
  play)
    QUERY="\$("\${VENV_DIR}/bin/python3" -c \
      "import sys,json; print(json.loads(sys.argv[1]).get('query',''))" \
      "\$INTENT_JSON" 2>/dev/null || echo "")"
    logit "[voice] Searching Kodi library for: \$QUERY"
    PLAY_ITEM="\$("\${VENV_DIR}/bin/python3" "\${VOICE_DIR}/kodi_search.py" \
      "\$QUERY" \
      "http://\${KODI_HOST}:\${KODI_PORT}/jsonrpc" \
      "\${KODI_USER}:\${KODI_PASS}" 2>>\$LOGFILE || echo "")"
    if [[ -n "\$PLAY_ITEM" ]]; then
      kodi_rpc "Player.Open" "{\"item\":\${PLAY_ITEM}}" >/dev/null
      RESPONSE="Playing \${QUERY}"
    else
      RESPONSE="I could not find \${QUERY} in your Kodi library."
    fi
    ;;
  pause)
    PID="\$(get_player_id)"
    [[ -n "\$PID" ]] && kodi_rpc "Player.PlayPause" "{\"playerid\":\${PID}}" >/dev/null
    RESPONSE="\${PID:+Paused}\${PID:-Nothing is playing}"
    ;;
  stop)
    PID="\$(get_player_id)"
    [[ -n "\$PID" ]] && kodi_rpc "Player.Stop" "{\"playerid\":\${PID}}" >/dev/null
    RESPONSE="\${PID:+Stopped}\${PID:-Nothing is playing}"
    ;;
  resume)
    PID="\$(get_player_id)"
    [[ -n "\$PID" ]] && kodi_rpc "Player.PlayPause" "{\"playerid\":\${PID}}" >/dev/null
    RESPONSE="\${PID:+Resumed}\${PID:-Nothing is playing}"
    ;;
  next)
    PID="\$(get_player_id)"
    [[ -n "\$PID" ]] && kodi_rpc "Player.GoTo" "{\"playerid\":\${PID},\"to\":\"next\"}" >/dev/null
    RESPONSE="\${PID:+Next}\${PID:-Nothing is playing}"
    ;;
  previous)
    PID="\$(get_player_id)"
    [[ -n "\$PID" ]] && kodi_rpc "Player.GoTo" "{\"playerid\":\${PID},\"to\":\"previous\"}" >/dev/null
    RESPONSE="\${PID:+Previous}\${PID:-Nothing is playing}"
    ;;
  volume)
    LEVEL="\$("\${VENV_DIR}/bin/python3" -c \
      "import sys,json; print(int(json.loads(sys.argv[1]).get('level',50)))" \
      "\$INTENT_JSON" 2>/dev/null || echo "50")"
    kodi_rpc "Application.SetVolume" "{\"volume\":\${LEVEL}}" >/dev/null
    RESPONSE="Volume set to \${LEVEL} percent"
    ;;
  answer|*)
    RESPONSE="\$("\${VENV_DIR}/bin/python3" -c \
      "import sys,json; print(json.loads(sys.argv[1]).get('response','I am not sure about that.'))" \
      "\$INTENT_JSON" 2>/dev/null || echo "I am not sure about that.")"
    ;;
esac

logit "[voice] Response: \$RESPONSE"

# 5. Speak response with Piper + aplay
logit "[voice] Synthesizing speech..."
echo "\$RESPONSE" | "\$PIPER_BIN" --model "\$VOICE_MODEL" --output_file "\$OUT_WAV" 2>>\$LOGFILE

if [[ "\$SPEAKER_DEVICE" == "default" ]]; then
  /usr/bin/aplay "\$OUT_WAV" 2>>\$LOGFILE
else
  /usr/bin/aplay -D "\$SPEAKER_DEVICE" "\$OUT_WAV" 2>>\$LOGFILE
fi

logit "[voice] Pipeline complete."
TRIGGER_EOF

chown "$REAL_USER:$(id -gn "$REAL_USER")" "$TRIGGER_SCRIPT"
chmod 750 "$TRIGGER_SCRIPT"
ok "Created $TRIGGER_SCRIPT"

# ─── 6. Prevent power button from shutting down (logind) ──────────────────────
log "=== Step 6: systemd-logind power key ==="

LOGIND_CONF="/etc/systemd/logind.conf"
if grep -qE '^HandlePowerKey=' "$LOGIND_CONF" 2>/dev/null; then
  sed -i.bak 's/^HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
  ok "Updated HandlePowerKey=ignore in $LOGIND_CONF"
elif grep -qE '^#HandlePowerKey=' "$LOGIND_CONF" 2>/dev/null; then
  sed -i.bak 's/^#HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
  ok "Uncommented and set HandlePowerKey=ignore in $LOGIND_CONF"
else
  echo "HandlePowerKey=ignore" >> "$LOGIND_CONF"
  ok "Appended HandlePowerKey=ignore to $LOGIND_CONF"
fi

warn "About to restart systemd-logind. This will terminate the current login session."
warn "Press Ctrl+C within 10 seconds to cancel."
sleep 10
systemctl restart systemd-logind || warn "Could not restart systemd-logind; you may need to reboot for power-button changes to take effect."

# Notify about KDE powerdevil if present
if [[ -f "$REAL_HOME/.config/powerdevilrc" ]] || command -v org_kde_powerdevil &>/dev/null; then
  warn "KDE powerdevil detected.  Ensure its power-button action is set to 'Do nothing' in System Settings → Power Management."
fi

# ─── 7. ACPI event binding ────────────────────────────────────────────────────
log "=== Step 7: ACPI event binding ==="

if ! systemctl is-enabled --quiet acpid 2>/dev/null; then
  systemctl enable --now acpid
  ok "acpid enabled and started"
else
  systemctl start acpid 2>/dev/null || true
  ok "acpid already enabled"
fi

ACPI_EVENTS_DIR="/etc/acpi/events"
install -d "$ACPI_EVENTS_DIR"

ACPI_EVENT_FILE="$ACPI_EVENTS_DIR/nuc-voice-assistant"
# Note: re-running setup.sh will overwrite this file.
# Pass --event 'your event string' to customise the match.
cat > "$ACPI_EVENT_FILE" << EVENTEOF
# NUC power button → voice assistant (managed by setup.sh)
event=${ACPI_EVENT_MATCH}
action=/etc/acpi/nuc-voice-assistant.sh %e
EVENTEOF
chmod 644 "$ACPI_EVENT_FILE"
ok "Created $ACPI_EVENT_FILE"

ACPI_ACTION="/etc/acpi/nuc-voice-assistant.sh"
cat > "$ACPI_ACTION" << ACTIONEOF
#!/usr/bin/env bash
# ACPI action: power button → voice assistant
# Called by acpid as root; uses flock to prevent overlapping invocations.
LOCK_FILE="/run/lock/nuc-voice-assistant.lock"
REAL_USER="${REAL_USER}"
VOICE_DIR="${VOICE_DIR}"
LOGFILE="${LOGFILE}"
XDG_RUNTIME_DIR="/run/user/\$(id -u "\$REAL_USER")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
logit() { echo "\$(ts) \$*" >> "\$LOGFILE"; }

logit "[acpi] Power button event: \$*"

# Guard: user must be logged in (XDG_RUNTIME_DIR must exist for audio to work)
if [[ ! -d "\$XDG_RUNTIME_DIR" ]]; then
  logit "[acpi] XDG_RUNTIME_DIR '\$XDG_RUNTIME_DIR' does not exist; '\$REAL_USER' may not be logged in. Aborting."
  exit 0
fi

# Prevent overlapping runs
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
  logit "[acpi] Already running; ignoring duplicate event."
  exit 0
fi

logit "[acpi] Launching voice_trigger.sh as \$REAL_USER"
export XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR"
# Run in background so acpid returns immediately (pipeline takes 10-30 s).
# The child is reparented to PID 1 (systemd) when this script exits — this is
# intentional and correct. Output is fully redirected to the log file.
sudo -u "\$REAL_USER" \
  XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
  "\$VOICE_DIR/voice_trigger.sh" >> "\$LOGFILE" 2>&1 &
PIPELINE_PID=\$!

# Save PID so it can be inspected if needed (e.g. kill a runaway pipeline)
echo "\$PIPELINE_PID" > /run/nuc-voice-assistant.pid
logit "[acpi] voice_trigger.sh launched (PID \$PIPELINE_PID)"
ACTIONEOF

chmod 755 "$ACPI_ACTION"
ok "Created $ACPI_ACTION"

systemctl restart acpid
ok "acpid restarted"

# ─── 8. Test command ──────────────────────────────────────────────────────────
log "=== Step 8: nuc-voice-test command ==="

TEST_CMD="/usr/local/bin/nuc-voice-test"
cat > "$TEST_CMD" << TESTEOF
#!/usr/bin/env bash
# nuc-voice-test — verify voice assistant + HTPC components
# Service checks (ollama, acpid) are done as-is; pipeline checks are always
# run as the real HTPC user (${REAL_USER}) to match the voice assistant's
# actual runtime environment.
set -euo pipefail

HTPC_USER="${REAL_USER}"
MODEL_NAME="${MODEL_NAME}"
LOGFILE="${LOGFILE}"
VOICE_DIR="${VOICE_DIR}"
VENV_DIR="${VOICE_DIR}/venv"
PIPER_BIN="${PIPER_BIN}"
VOICE_MODEL="${VOICES_DIR}/en_US-lessac-medium.onnx"
SPEAKER_DEVICE="${SPEAKER_DEVICE}"
KODI_HOST="${KODI_HOST}"
KODI_PORT="${KODI_PORT}"
KODI_USER="${KODI_USER}"
KODI_PASS="${KODI_PASS}"

OUT_WAV="\${VOICE_DIR}/tmp/nuc_voice_test.wav"
TEST_PHRASE="Voice assistant test successful."

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
logit() { echo "\$(ts) \$*" | tee -a "\$LOGFILE"; }

echo "=== NUC HTPC — Self Test ==="

# ── Service checks (safe to run as root or user) ────────────────────────────

# 1. ollama
echo -n "  ollama version ... "
ollama --version && echo "  ✓ ollama OK" || { echo "  ✗ ollama FAILED"; exit 1; }

# 2. ollama service
echo -n "  ollama service  ... "
if systemctl is-active --quiet ollama 2>/dev/null; then
  echo "running ✓"
else
  echo "NOT running ✗"; exit 1
fi

# 3. acpid service
echo -n "  acpid service   ... "
if systemctl is-active --quiet acpid 2>/dev/null; then
  echo "running ✓"
else
  echo "NOT running ✗"; exit 1
fi

# 4. Kodi JSON-RPC reachability (non-fatal — Kodi may not be running yet)
echo -n "  Kodi JSON-RPC   ... "
if curl -sf --max-time 5 \
    -u "\${KODI_USER}:\${KODI_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"JSONRPC.Ping","id":1}' \
    "http://\${KODI_HOST}:\${KODI_PORT}/jsonrpc" 2>/dev/null | grep -q '"pong"'; then
  echo "reachable ✓"
else
  echo "not reachable (start Kodi and enable HTTP remote control to use voice commands) ⚠"
fi

# ── Pipeline checks — re-exec as HTPC_USER if currently root ───────────────
# This ensures we test the exact environment the voice assistant uses.
if [[ \$EUID -eq 0 ]] && [[ "\$(whoami)" != "\$HTPC_USER" ]]; then
  echo "  (re-running pipeline checks as \$HTPC_USER...)"
  exec sudo -u "\$HTPC_USER" "\$0" --pipeline-only
fi

# 5. faster-whisper importable
echo -n "  faster-whisper  ... "
"\$VENV_DIR/bin/python3" -c "import faster_whisper; print('importable ✓')" || { echo "FAILED ✗"; exit 1; }

# 6. intent_detect.py present
echo -n "  intent_detect   ... "
[[ -f "\${VOICE_DIR}/intent_detect.py" ]] && echo "present ✓" || { echo "MISSING ✗"; exit 1; }

# 7. kodi_search.py present
echo -n "  kodi_search     ... "
[[ -f "\${VOICE_DIR}/kodi_search.py" ]] && echo "present ✓" || { echo "MISSING ✗"; exit 1; }

# 8. piper binary
echo -n "  piper binary    ... "
if [[ -x "\$PIPER_BIN" ]] || command -v piper &>/dev/null; then
  echo "found ✓"
else
  echo "NOT found ✗"; exit 1
fi

# 9. voice model
echo -n "  voice model     ... "
[[ -f "\$VOICE_MODEL" ]] && echo "present ✓" || { echo "MISSING ✗"; exit 1; }

# 10. LLM prompt test
echo "  LLM test prompt ..."
if RESPONSE="\$(ollama run "\$MODEL_NAME" "Reply only: test OK" 2>/dev/null)" && [[ -n "\$RESPONSE" ]]; then
  echo "    LLM reply: \$(echo "\$RESPONSE" | head -1) ✓"
else
  echo "  ✗ LLM test FAILED (empty or error response)"; exit 1
fi

# 11. TTS + playback test
echo "  TTS test ..."
mkdir -p "\$(dirname "\$OUT_WAV")" && chmod 700 "\$(dirname "\$OUT_WAV")"
echo "\$TEST_PHRASE" | "\$PIPER_BIN" --model "\$VOICE_MODEL" --output_file "\$OUT_WAV" 2>/dev/null
if [[ "\$SPEAKER_DEVICE" == "default" ]]; then
  aplay "\$OUT_WAV" 2>/dev/null && echo "  ✓ Audio played OK"
else
  aplay -D "\$SPEAKER_DEVICE" "\$OUT_WAV" 2>/dev/null && echo "  ✓ Audio played OK"
fi
rm -f "\$OUT_WAV"

# Only log "success" from the final user context (not the root wrapper)
if [[ \$EUID -ne 0 ]]; then
  logit "[test] nuc-voice-test ran successfully"
fi
echo ""
echo "=== All checks passed ==="

# Support --pipeline-only flag used when re-exec-ed as HTPC_USER
[[ "\${1:-}" == "--pipeline-only" ]] && exit 0
true
TESTEOF

chmod 755 "$TEST_CMD"
ok "Created $TEST_CMD"

# ─── 9. Log file initialisation ───────────────────────────────────────────────
log "=== Step 9: Log file ==="
touch "$LOGFILE"
chmod 664 "$LOGFILE"
chown "$REAL_USER:$(id -gn "$REAL_USER")" "$LOGFILE"
echo "$(date '+%Y-%m-%dT%H:%M:%S') [setup] Installation complete." >> "$LOGFILE"
ok "Log file ready: $LOGFILE"

# ─── 10. Steam + Gamescope autostart (Phase 1 + 4) ───────────────────────────
log "=== Step 10: Steam + Gamescope autostart ==="

AUTOSTART_DIR="$REAL_HOME/.config/autostart"
install -d -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$AUTOSTART_DIR"

STEAM_DESKTOP="$AUTOSTART_DIR/steam-gaming.desktop"
cat > "$STEAM_DESKTOP" << DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Steam Gaming Mode
Comment=Launch Steam Gamepad UI via gamescope (managed by setup.sh)
Exec=gamescope -f -r ${FRAMERATE} -w ${RENDER_WIDTH} -h ${RENDER_HEIGHT} -W ${TV_WIDTH} -H ${TV_HEIGHT} -- steam -gamepadui
X-GNOME-Autostart-enabled=true
DESKTOPEOF

chown "$REAL_USER:$(id -gn "$REAL_USER")" "$STEAM_DESKTOP"
chmod 644 "$STEAM_DESKTOP"
ok "Created $STEAM_DESKTOP"
ok "gamescope args: -f -r ${FRAMERATE} -w ${RENDER_WIDTH} -h ${RENDER_HEIGHT} -W ${TV_WIDTH} -H ${TV_HEIGHT}"

if ! command -v gamescope &>/dev/null; then
  warn "gamescope not found in PATH; install it (dnf install gamescope) for the autostart to work."
fi
if ! command -v steam &>/dev/null; then
  warn "steam not found in PATH; install it (dnf install steam) for the autostart to work."
fi

# ─── 11. Kodi HTTP API configuration (Phase 2 + 3) ────────────────────────────
log "=== Step 11: Kodi HTTP API configuration ==="

KODI_USERDATA="$REAL_HOME/.kodi/userdata"
install -d -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$KODI_USERDATA"

KODI_ADVSETTINGS="$KODI_USERDATA/advancedsettings.xml"
if [[ ! -f "$KODI_ADVSETTINGS" ]]; then
  cat > "$KODI_ADVSETTINGS" << KODIXML
<advancedsettings>
  <services>
    <webserver>true</webserver>
    <webserverport>${KODI_PORT}</webserverport>
    <webserverusername>${KODI_USER}</webserverusername>
    <webserverpassword>${KODI_PASS}</webserverpassword>
    <zeroconf>true</zeroconf>
  </services>
</advancedsettings>
KODIXML
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$KODI_ADVSETTINGS"
  chmod 644 "$KODI_ADVSETTINGS"
  ok "Created Kodi advancedsettings.xml (HTTP JSON-RPC on port ${KODI_PORT})"
else
  ok "Kodi advancedsettings.xml already exists; skipping (edit $KODI_ADVSETTINGS manually if needed)"
fi

warn "In Kodi: Settings → Services → Control → enable 'Allow remote control via HTTP' and set the same port/credentials."
warn "Add Kodi to Steam: Steam → Add Non-Steam Game → Kodi."

# ─── 12. Appliance mode (Phase 5) ─────────────────────────────────────────────
log "=== Step 12: Appliance mode ==="

# Disable DPMS / screen blanking via an autostart script that runs xset
XSET_DESKTOP="$AUTOSTART_DIR/disable-screen-blanking.desktop"
cat > "$XSET_DESKTOP" << XSETEOF
[Desktop Entry]
Type=Application
Name=Disable Screen Blanking
Comment=Keep the TV on (HTPC appliance mode — managed by setup.sh)
Exec=bash -c "xset dpms 0 0 0 && xset s off && xset s noblank"
X-GNOME-Autostart-enabled=true
XSETEOF
chown "$REAL_USER:$(id -gn "$REAL_USER")" "$XSET_DESKTOP"
chmod 644 "$XSET_DESKTOP"
ok "Created $XSET_DESKTOP (disables DPMS/screen blanking on login)"

# KDE Power Management — disable all sleep/hibernate actions
KDE_POWER_CFG="$REAL_HOME/.config/powermanagementprofilesrc"
if [[ ! -f "$KDE_POWER_CFG" ]]; then
  cat > "$KDE_POWER_CFG" << KDEPOWER
[AC][DPMSControl]
idleTime=0
lockBeforeTurnOff=0
turnOffDisplayWhenIdle=false

[AC][DimDisplay]
idleTime=0
whenIdle=false

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=0
powerDownAction=0

[AC][SuspendSession]
idleTime=0
suspendThenHibernate=false
suspendType=0
whenIdle=false
KDEPOWER
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$KDE_POWER_CFG"
  chmod 644 "$KDE_POWER_CFG"
  ok "Created KDE power management profile (appliance mode — no sleep/suspend)"
else
  ok "KDE power management config already exists; skipping (edit $KDE_POWER_CFG manually if needed)"
fi

# Suppress KDE desktop notifications for a clean TV-facing experience
KDE_NOTIFY_CFG="$REAL_HOME/.config/plasmanotifyrc"
if [[ ! -f "$KDE_NOTIFY_CFG" ]]; then
  cat > "$KDE_NOTIFY_CFG" << KDNOTIFY
[DoNotDisturb]
Until=0000-00-00T00:00:00
WhenRunningFullscreen=true
KDNOTIFY
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$KDE_NOTIFY_CFG"
  chmod 644 "$KDE_NOTIFY_CFG"
  ok "Created KDE notification config (suppressed during fullscreen)"
else
  ok "KDE notification config already exists; skipping"
fi

# ─── 13. Non-Steam shortcuts helper (Phase 6) ─────────────────────────────────
log "=== Step 13: Non-Steam shortcuts helper ==="

ADD_SHORTCUTS_CMD="/usr/local/bin/htpc-add-steam-shortcuts"
cat > "$ADD_SHORTCUTS_CMD" << 'SHORTCUTS_EOF'
#!/usr/bin/env bash
# htpc-add-steam-shortcuts — add HTPC apps (Kodi, Firefox, Dolphin, RetroArch,
# Moonlight) as non-Steam games so they appear in the Steam Gamepad UI.
#
# Run this script AFTER Steam has been launched at least once (so that the
# Steam userdata directory and shortcuts.vdf file exist).
#
# Usage: htpc-add-steam-shortcuts [--dry-run]
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STEAM_ROOT="${HOME}/.local/share/Steam"
if [[ ! -d "$STEAM_ROOT" ]]; then
  echo "Error: Steam root not found at $STEAM_ROOT." >&2
  echo "       Launch Steam at least once before running this script." >&2
  exit 1
fi

# Locate the first Steam user's shortcuts.vdf
USERDATA_DIR="$STEAM_ROOT/userdata"
SHORTCUTS_VDF=""
for uid_dir in "$USERDATA_DIR"/*/; do
  candidate="$uid_dir/config/shortcuts.vdf"
  if [[ -d "$uid_dir" ]] && [[ "${uid_dir##*/}" =~ ^[0-9]+$ ]]; then
    SHORTCUTS_VDF="$candidate"
    break
  fi
done

if [[ -z "$SHORTCUTS_VDF" ]]; then
  echo "Error: no Steam user account found in $USERDATA_DIR." >&2
  echo "       Log in to Steam at least once before running this script." >&2
  exit 1
fi

echo "Target shortcuts.vdf: $SHORTCUTS_VDF"
install -d "$(dirname "$SHORTCUTS_VDF")"

# Build shortcuts using Python (standard library only — no pip packages needed)
PYTHON_CMD="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
if [[ -z "$PYTHON_CMD" ]]; then
  echo "Error: python3 not found." >&2; exit 1
fi

# Declare apps to add: "AppName|Exe|Icon"
declare -a HTPC_APPS=(
  "Kodi|/usr/bin/kodi|/usr/share/pixmaps/kodi.png"
  "Firefox|/usr/bin/firefox|/usr/lib64/firefox/browser/chrome/icons/default/default128.png"
  "Dolphin Emulator|/usr/bin/dolphin-emu|/usr/share/pixmaps/dolphin-emu.png"
  "RetroArch|/usr/bin/retroarch|/usr/share/pixmaps/retroarch.png"
  "Moonlight|/usr/bin/moonlight-qt|"
)

$DRY_RUN && echo "[dry-run] Would write to: $SHORTCUTS_VDF" && exit 0

"$PYTHON_CMD" - "$SHORTCUTS_VDF" "${HTPC_APPS[@]}" << 'PYEOF'
"""Append non-Steam shortcuts to Steam's binary shortcuts.vdf.

The shortcuts.vdf format is a simple binary Key/Value store:
  \x00shortcuts\x00
    \x00<index>\x00
      \x01appname\x00<name>\x00
      \x01exe\x00<path>\x00
      \x01StartDir\x00<dir>\x00
      \x01icon\x00<path>\x00
      \x01tags\x00\x08\x08
    \x08\x08
  \x08\x08
"""
import os, struct, sys

vdf_path = sys.argv[1]
app_specs = sys.argv[2:]

def read_vdf(path):
    if os.path.exists(path):
        with open(path, "rb") as f:
            return f.read()
    return b""

def parse_entries(data):
    """Return list of raw entry byte-strings from an existing shortcuts.vdf."""
    entries = []
    # Skip header: \x00shortcuts\x00
    hdr = b"\x00shortcuts\x00"
    if not data.startswith(hdr):
        return entries
    pos = len(hdr)
    # Each entry starts with \x00<idx>\x00 and ends with \x08\x08
    while pos < len(data) - 1:
        if data[pos] == 0x08:  # outer terminator
            break
        end = data.find(b"\x08\x08", pos)
        if end == -1:
            break
        entries.append(data[pos:end + 2])
        pos = end + 2
    return entries

def make_entry(idx, name, exe, icon=""):
    start_dir = os.path.dirname(exe) if exe else ""
    entry  = b"\x00" + str(idx).encode() + b"\x00"
    entry += b"\x01appname\x00"   + name.encode()       + b"\x00"
    entry += b"\x01exe\x00"       + exe.encode()         + b"\x00"
    entry += b"\x01StartDir\x00"  + start_dir.encode()   + b"\x00"
    entry += b"\x01icon\x00"      + icon.encode()         + b"\x00"
    entry += b"\x01tags\x00\x08\x08"
    return entry

def write_vdf(path, entries):
    data = b"\x00shortcuts\x00"
    for entry in entries:
        data += entry
    data += b"\x08\x08"
    with open(path, "wb") as f:
        f.write(data)

raw = read_vdf(vdf_path)
existing = parse_entries(raw)
existing_names = set()
for e in existing:
    idx = e.find(b"\x01appname\x00")
    if idx != -1:
        start = idx + len(b"\x01appname\x00")
        end = e.find(b"\x00", start)
        existing_names.add(e[start:end].decode(errors="replace"))

next_idx = len(existing)
added = 0
for spec in app_specs:
    parts = spec.split("|")
    name = parts[0] if len(parts) > 0 else ""
    exe  = parts[1] if len(parts) > 1 else ""
    icon = parts[2] if len(parts) > 2 else ""
    if name in existing_names:
        print(f"  skip (already present): {name}")
        continue
    existing.append(make_entry(next_idx, name, exe, icon))
    next_idx += 1
    added += 1
    print(f"  added: {name} ({exe})")

if added > 0:
    write_vdf(vdf_path, existing)
    print(f"\nAdded {added} shortcut(s) to {vdf_path}")
    print("Restart Steam for changes to take effect.")
else:
    print("No new shortcuts to add.")
PYEOF
SHORTCUTS_EOF

chmod 755 "$ADD_SHORTCUTS_CMD"
ok "Created $ADD_SHORTCUTS_CMD"
ok "Run 'htpc-add-steam-shortcuts' after launching Steam once to add HTPC apps to the Game Pad UI"

# ─── 14. Verification summary ─────────────────────────────────────────────────
cat << SUMMARY

╔══════════════════════════════════════════════════════════════════╗
║        NUC HTPC (Fire TV Cube Replacement) — Setup Complete       ║
╚══════════════════════════════════════════════════════════════════╝

 ── Voice assistant ──────────────────────────────────────────────
 Check services:
   systemctl status ollama
   systemctl status acpid

 Monitor power button presses (run as root, then press the button):
   sudo acpi_listen

 If the event line differs from the default, re-run with:
   sudo ./setup.sh --event '<paste event line here>'

 Tail the assistant log:
   sudo tail -f /var/log/nuc-voice-assistant.log

 Run the full self-test:
   nuc-voice-test

 ── Steam Gamepad UI (Phase 1 + 4) ───────────────────────────────
 Autostart entry: ${REAL_HOME}/.config/autostart/steam-gaming.desktop
 Gamescope: render ${RENDER_WIDTH}x${RENDER_HEIGHT} → TV ${TV_WIDTH}x${TV_HEIGHT} @ ${FRAMERATE}fps
 To change resolution, re-run:
   sudo ./setup.sh --render-width 1920 --render-height 1080 --tv-width 3840 --tv-height 2160

 ── Kodi (Phase 2 + 3) ───────────────────────────────────────────
 HTTP JSON-RPC configured on http://${KODI_HOST}:${KODI_PORT}
 In Kodi: Settings → Services → Control → enable "Allow remote control via HTTP"
 Add Kodi to Steam Gamepad UI: Steam → Add Non-Steam Game → Kodi

 Voice commands (press the front button, then speak):
   "Play Stargate Universe"  →  Kodi searches library and plays
   "Pause"                   →  Pauses current playback
   "Stop"                    →  Stops playback
   "Volume 50"               →  Sets Kodi volume to 50%

 ── Add more apps to Steam Gamepad UI (Phase 6) ──────────────────
 After launching Steam once, run:
   htpc-add-steam-shortcuts
 This adds Kodi, Firefox, Dolphin, RetroArch, and Moonlight.

 ── Appliance mode (Phase 5) ─────────────────────────────────────
 Screen blanking disabled via autostart xset script
 KDE power management set to never sleep/suspend
 KDE notifications suppressed in fullscreen

SUMMARY
