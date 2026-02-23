#!/usr/bin/env bash
# setup.sh — Idempotent NUC voice-assistant installer for Nobara HTPC
# Usage:  sudo ./setup.sh [--event 'button/power PBTN 00000080 00000000']
#                         [--model mistral]  [--record-seconds 5]
#                         [--mic-device hw:0,0] [--speaker-device hw:0,0]
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

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)         ACPI_EVENT_MATCH="$2"; shift 2 ;;
    --model)         MODEL_NAME="$2"; shift 2 ;;
    --record-seconds) RECORD_SECONDS="$2"; shift 2 ;;
    --mic-device)    MIC_DEVICE="$2"; shift 2 ;;
    --speaker-device) SPEAKER_DEVICE="$2"; shift 2 ;;
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

# ─── 5. Create voice_trigger.sh ───────────────────────────────────────────────
log "=== Step 5: voice_trigger.sh ==="

TRIGGER_SCRIPT="$VOICE_DIR/voice_trigger.sh"

cat > "$TRIGGER_SCRIPT" << TRIGGER_EOF
#!/usr/bin/env bash
# voice_trigger.sh — STT → LLM → TTS pipeline
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

# Private temp directory — 700 so other users cannot read recorded audio/transcripts
TMP_DIR="\${VOICE_DIR}/tmp"
mkdir -p "\$TMP_DIR"
chmod 700 "\$TMP_DIR"
IN_WAV="\${TMP_DIR}/nuc_assistant_in.wav"
OUT_WAV="\${TMP_DIR}/nuc_assistant_out.wav"
TRANSCRIPT_FILE="\${TMP_DIR}/nuc_assistant_transcript.txt"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
logit() { echo "\$(ts) \$*" | tee -a "\$LOGFILE"; }

# Clean up temp files on exit (success or error)
cleanup() { rm -f "\$IN_WAV" "\$OUT_WAV" "\$TRANSCRIPT_FILE"; }
trap cleanup EXIT

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${VENV_DIR}/bin"

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

# 3. Query Ollama
logit "[voice] Querying Ollama model: \$MODEL_NAME"
RESPONSE="\$(ollama run "\$MODEL_NAME" "\$TRANSCRIPT" 2>>\$LOGFILE || echo "I'm sorry, I could not get a response.")"
logit "[voice] Response: \$RESPONSE"

# 4. Speak response with Piper + aplay
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
# nuc-voice-test — verify voice assistant components
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

OUT_WAV="\${VOICE_DIR}/tmp/nuc_voice_test.wav"
TEST_PHRASE="Voice assistant test successful."

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
logit() { echo "\$(ts) \$*" | tee -a "\$LOGFILE"; }

echo "=== NUC Voice Assistant — Self Test ==="

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

# ── Pipeline checks — re-exec as HTPC_USER if currently root ───────────────
# This ensures we test the exact environment the voice assistant uses.
if [[ \$EUID -eq 0 ]] && [[ "\$(whoami)" != "\$HTPC_USER" ]]; then
  echo "  (re-running pipeline checks as \$HTPC_USER...)"
  exec sudo -u "\$HTPC_USER" "\$0" --pipeline-only
fi

# 4. faster-whisper importable
echo -n "  faster-whisper  ... "
"\$VENV_DIR/bin/python3" -c "import faster_whisper; print('importable ✓')" || { echo "FAILED ✗"; exit 1; }

# 5. piper binary
echo -n "  piper binary    ... "
if [[ -x "\$PIPER_BIN" ]] || command -v piper &>/dev/null; then
  echo "found ✓"
else
  echo "NOT found ✗"; exit 1
fi

# 6. voice model
echo -n "  voice model     ... "
[[ -f "\$VOICE_MODEL" ]] && echo "present ✓" || { echo "MISSING ✗"; exit 1; }

# 7. LLM prompt test
echo "  LLM test prompt ..."
if RESPONSE="\$(ollama run "\$MODEL_NAME" "Reply only: test OK" 2>/dev/null)" && [[ -n "\$RESPONSE" ]]; then
  echo "    LLM reply: \$(echo "\$RESPONSE" | head -1) ✓"
else
  echo "  ✗ LLM test FAILED (empty or error response)"; exit 1
fi

# 8. TTS + playback test
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

# ─── 10. Verification summary ─────────────────────────────────────────────────
cat << 'SUMMARY'

╔══════════════════════════════════════════════════════════════════╗
║            NUC Voice Assistant — Setup Complete                  ║
╚══════════════════════════════════════════════════════════════════╝

 Check services:
   systemctl status ollama
   systemctl status acpid

 Monitor power button presses (run as root, then press the button):
   sudo acpi_listen

 If the event line differs from the default, re-run with:
   sudo ./setup.sh --event '<paste event line here>'

 Tail the assistant log:
   sudo tail -f /var/log/nuc-voice-assistant.log

 Run the self-test:
   nuc-voice-test

SUMMARY
