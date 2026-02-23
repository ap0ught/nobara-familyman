# nobara-familyman

Idempotent setup script that turns a fresh **Nobara HTPC** (Intel NUC8i7HNK) into a local, offline voice assistant triggered by the front power button.

## Architecture

| Layer | Component |
|-------|-----------|
| Speech-to-text | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (Python venv, CPU) |
| LLM | [Ollama](https://ollama.com) — default model `mistral` |
| Text-to-speech | [Piper TTS](https://github.com/rhasspy/piper) + `en_US-lessac-medium` voice |
| Trigger | ACPI power-button event → `acpid` action |

## Quick Start

```bash
git clone https://github.com/ap0ught/nobara-familyman.git
cd nobara-familyman
sudo ./setup.sh
```

Re-running is safe — the script is fully **idempotent**.

## The `familyman` User

The script creates a dedicated `familyman` account if it does not already exist and configures it as the HTPC's primary user:

- Added to the `wheel`, `audio`, and `video` groups
- Granted **passwordless sudo** via `/etc/sudoers.d/familyman`
- Configured for **autologin** via SDDM (KDE / Nobara default) or GDM (fallback)

The voice-assistant pipeline always runs as `familyman`, regardless of which account invokes `setup.sh`.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--model NAME` | `mistral` | Ollama model to pull and use |
| `--record-seconds N` | `5` | Seconds of audio to capture per press |
| `--event 'STRING'` | `button/power.*` | Exact ACPI event match string |
| `--mic-device DEVICE` | `default` | ALSA capture device (e.g. `hw:1,0`) |
| `--speaker-device DEVICE` | `default` | ALSA playback device |

Environment variables (`MODEL_NAME`, `RECORD_SECONDS`, `MIC_DEVICE`, `SPEAKER_DEVICE`) are also honoured and can override defaults before running the script.

To pin the Piper binary to a specific version and verify its integrity:

```bash
PIPER_VERSION=2023.11.14-2 PIPER_SHA256=<sha256sum> sudo ./setup.sh
```

### Custom ACPI event

If `sudo acpi_listen` shows a different event string than `button/power.*`, re-run:

```bash
sudo ./setup.sh --event 'button/power PBTN 00000080 00000000'
```

> **Note:** re-running `setup.sh` overwrites the ACPI event file with the new (or default) event string.

## What the Script Does

0. **`familyman` user** — creates user, grants passwordless sudo, configures autologin (SDDM/GDM)
1. **System deps** — installs `acpid`, `alsa-utils`, `python3`, `piper`, etc. via `dnf`
2. **Ollama** — installs via official script, enables systemd service, pulls the chosen model
3. **faster-whisper venv** — creates `~/voice_assistant/venv`, installs `faster-whisper`, and **pre-downloads the Whisper `base` model** so the assistant runs fully offline after setup
4. **Piper TTS** — uses distro package if available; otherwise downloads a pinned release binary (see `PIPER_VERSION`) and the `en_US-lessac-medium` voice model from HuggingFace
5. **voice_trigger.sh** — deploys `~/voice_assistant/voice_trigger.sh` (record → transcribe → LLM → speak); audio files are kept in a private `~/voice_assistant/tmp/` directory (mode 700) and deleted after each run
6. **Power button** — sets `HandlePowerKey=ignore` in `/etc/systemd/logind.conf` (backup saved as `.bak`) — warns before restarting `systemd-logind` as it will end the current session
7. **ACPI binding** — creates `/etc/acpi/events/nuc-voice-assistant` and `/etc/acpi/nuc-voice-assistant.sh` with `flock` (lock file in `/run/lock/`) to prevent overlapping invocations; checks that the user is logged in before starting the pipeline
8. **Test command** — installs `/usr/local/bin/nuc-voice-test`

## Files Created / Modified

| Path | Description |
|------|-------------|
| `/etc/sudoers.d/familyman` | Passwordless sudo for `familyman` |
| `/etc/sddm.conf.d/autologin.conf` | SDDM autologin (or GDM `custom.conf`) |
| `~/voice_assistant/voice_trigger.sh` | Main STT→LLM→TTS pipeline script |
| `~/voice_assistant/venv/` | Python virtual environment |
| `~/voice_assistant/voices/` | Piper voice models |
| `~/voice_assistant/tmp/` | Private temp dir for audio/transcripts (mode 700) |
| `~/voice_assistant/bin/piper` | Piper binary (if not available via DNF) |
| `/etc/systemd/logind.conf` | `HandlePowerKey=ignore` added/updated (`.bak` backup) |
| `/etc/acpi/events/nuc-voice-assistant` | ACPI event rule |
| `/etc/acpi/nuc-voice-assistant.sh` | ACPI action script |
| `/usr/local/bin/nuc-voice-test` | Self-test command |
| `/var/log/nuc-voice-assistant.log` | Timestamped log (owned by `familyman`) |

## Verification

After setup, run:

```bash
# Self-test (checks all components, plays a test phrase)
nuc-voice-test

# Check services
systemctl status ollama
systemctl status acpid

# Watch button events in real time (press the NUC power button)
sudo acpi_listen

# Tail the assistant log
sudo tail -f /var/log/nuc-voice-assistant.log
```

## Requirements

- Nobara Linux (Fedora-based, uses `dnf`)
- Internet access during setup (to download Ollama, the LLM model, the Piper voice, and the Whisper model)
- A microphone and speaker/headphone output
- Root access (`sudo`)
