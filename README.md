# nobara-familyman

A collection of idempotent setup scripts that turn a fresh **Nobara HTPC** (Intel NUC8i7HNK) into a multi-purpose home appliance.

| Plan | Script | Description |
|------|--------|-------------|
| [Plan 1 — Voice Assistant](#plan-1--voice-assistant) | `setup.sh` | Local, offline voice assistant triggered by the front power button |
| [Plan 2 — MagicMirror²](#plan-2--magicmirror-for-63021) | `setup-magicmirror.sh` | Fullscreen smart-mirror display with weather, calendar, and time for zip 63021 |

---

## Plan 1 — Voice Assistant

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

---

## Plan 2 — MagicMirror² for 63021

Turn the NUC into a fullscreen smart-mirror / home info panel pre-configured for the **63021** zip-code area (Ballwin, MO).

### Architecture

```
Boot
  ↓
Auto Login (familyman)
  ↓
Minimal KDE session
  ↓
MagicMirror² fullscreen (Electron)
  ↓
Modules auto-refresh
```

### Quick Start

```bash
sudo ./setup-magicmirror.sh
```

Then edit `~/MagicMirror/config/config.js` to set your API key and calendar URL.

Re-running is safe — the script is fully **idempotent**.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--user NAME` | `familyman` | HTPC user that will run MagicMirror² |
| `--api-key KEY` | `YOUR_API_KEY` | OpenWeatherMap API key |
| `--calendar-url URL` | `YOUR_ICS_URL` | Google/iCal `.ics` calendar feed URL |
| `--location-id ID` | `4387778` | OpenWeatherMap city ID (default: Ballwin, MO) |
| `--location NAME` | `Ballwin` | Human-readable location name shown in config |

Environment variables (`OPENWEATHER_API_KEY`, `CALENDAR_URL`, `LOCATION_ID`, `LOCATION_NAME`) are also honoured.

Example with credentials:

```bash
OPENWEATHER_API_KEY=abc123 CALENDAR_URL=https://calendar.google.com/... \
  sudo ./setup-magicmirror.sh
```

### What the Script Does

1. **System deps** — installs `git`, `curl`, `nodejs`, `npm`, and `unclutter` (if available) via `dnf`
2. **MagicMirror² source** — clones (or updates) the repo into `~/MagicMirror`
3. **npm install** — installs all MagicMirror² Node dependencies (including Electron)
4. **config/config.js** — writes a ready-to-use config pre-set for 63021 (Ballwin, MO):
   - 12-hour clock, imperial units, US English locale
   - Current weather + 5-day forecast via OpenWeatherMap
   - Calendar module (iCal URL)
   - News feed (Reuters)
   - Compliments module
5. **Fullscreen mode** — patches `package.json` to add `--fullscreen --no-sandbox` to the Electron start command
6. **KDE autostart entries** (in `~/.config/autostart/`):
   - `magicmirror.desktop` — starts MagicMirror² on login
   - `unclutter.desktop` — hides the mouse cursor (if unclutter is installed)
   - `disable-screensaver.desktop` — disables screen blanking via `xset`

### Post-Install Configuration

Edit the config file to supply real credentials:

```bash
nano ~/MagicMirror/config/config.js
```

Replace:

```js
apiKey: "YOUR_API_KEY"   // ← your OpenWeatherMap API key
url: "YOUR_ICS_URL"      // ← your Google/iCal .ics URL
```

Get a free OpenWeatherMap API key at <https://openweathermap.org/api>.

### Test Run

```bash
sudo -u familyman npm start --prefix ~/MagicMirror
```

### Files Created / Modified

| Path | Description |
|------|-------------|
| `~/MagicMirror/` | MagicMirror² application |
| `~/MagicMirror/config/config.js` | Mirror config (clock, weather, calendar, news) |
| `~/.config/autostart/magicmirror.desktop` | KDE autostart entry |
| `~/.config/autostart/unclutter.desktop` | Cursor-hiding autostart entry (if unclutter available) |
| `~/.config/autostart/disable-screensaver.desktop` | Screen-blanking prevention autostart entry |

### Dual-Mode (Steam + Mirror)

To run both Steam HTPC mode and MagicMirror mode on the same NUC:

- **Two users**: create `htpc` (Steam autologin) and `mirror` (MagicMirror autologin), switch via user accounts.
- **Boot script**: detect connected display orientation and launch the appropriate mode.
- **Voice trigger**: integrate with Plan 1 — a voice command kills Steam and launches MagicMirror (or vice versa).

### Requirements

- Nobara Linux (Fedora-based, uses `dnf`)
- Internet access during setup (to clone MagicMirror² and install npm packages)
- A display connected to the NUC
- Root access (`sudo`)
- `familyman` user must already exist (run `setup.sh` first, or pass `--user <name>`)
