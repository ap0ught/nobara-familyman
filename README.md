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

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--model NAME` | `mistral` | Ollama model to pull and use |
| `--record-seconds N` | `5` | Seconds of audio to capture per press |
| `--event 'STRING'` | `button/power.*` | Exact ACPI event match string |
| `--mic-device DEVICE` | `default` | ALSA capture device (e.g. `hw:1,0`) |
| `--speaker-device DEVICE` | `default` | ALSA playback device |

Environment variables (`MODEL_NAME`, `RECORD_SECONDS`, `MIC_DEVICE`, `SPEAKER_DEVICE`) are also honoured and can override defaults before running the script.

### Custom ACPI event

If `sudo acpi_listen` shows a different event string than `button/power.*`, re-run:

```bash
sudo ./setup.sh --event 'button/power PBTN 00000080 00000000'
```

## What the Script Does

1. **System deps** — installs `acpid`, `alsa-utils`, `python3`, `piper`, etc. via `dnf`
2. **Ollama** — installs via official script, enables systemd service, pulls the chosen model
3. **faster-whisper venv** — creates `~/voice_assistant/venv` and installs `faster-whisper`
4. **Piper TTS** — uses distro package if available; otherwise downloads the release binary and the `en_US-lessac-medium` voice model from HuggingFace
5. **voice_trigger.sh** — deploys `~/voice_assistant/voice_trigger.sh` (record → transcribe → LLM → speak)
6. **Power button** — sets `HandlePowerKey=ignore` in `/etc/systemd/logind.conf` so the button no longer shuts down / suspends the machine
7. **ACPI binding** — creates `/etc/acpi/events/nuc-voice-assistant` and `/etc/acpi/nuc-voice-assistant.sh` with `flock` to prevent overlapping invocations
8. **Test command** — installs `/usr/local/bin/nuc-voice-test`

## Files Created / Modified

| Path | Description |
|------|-------------|
| `~/voice_assistant/voice_trigger.sh` | Main STT→LLM→TTS pipeline script |
| `~/voice_assistant/venv/` | Python virtual environment |
| `~/voice_assistant/voices/` | Piper voice models |
| `~/voice_assistant/bin/piper` | Piper binary (if not available via DNF) |
| `/etc/systemd/logind.conf` | `HandlePowerKey=ignore` added/updated |
| `/etc/acpi/events/nuc-voice-assistant` | ACPI event rule |
| `/etc/acpi/nuc-voice-assistant.sh` | ACPI action script |
| `/usr/local/bin/nuc-voice-test` | Self-test command |
| `/var/log/nuc-voice-assistant.log` | Timestamped log |

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
- Internet access during setup (to download Ollama, the LLM model, and the Piper voice)
- A microphone and speaker/headphone output
- Root access (`sudo`)
