# nobara-familyman

A collection of idempotent setup scripts that turn a fresh **Nobara HTPC** (Intel NUC8i7HNK) into a multi-purpose home appliance.

| Plan | Script | Description |
|------|--------|-------------|
| [Plan 1 — HTPC / Fire TV Cube replacement](#architecture) | `setup.sh` | Steam Gamepad UI + voice-controlled Kodi + local AI |
| [Plan 2 — MagicMirror²](#plan-2--magicmirror-for-63021) | `setup-magicmirror.sh` | Fullscreen smart-mirror display for zip 63021 (Ballwin, MO) |

---

Idempotent setup script that turns a fresh **Nobara HTPC** (Intel NUC8i7HNK) into a **Fire TV Cube replacement** — a clean, controller-first Linux appliance that boots directly into the Steam Gamepad UI, supports voice-triggered Kodi playback, emulation, and local AI, with no visible desktop.

## Architecture

```
Power On → Auto Login (familyman) → Gamescope Session → Steam Gamepad UI
                                                               ↓
                               ┌───────────────────────────────┤
                               │  Kodi  │  Firefox  │  Dolphin │  RetroArch  │  Moonlight
                               └───────────────────────────────┘

Front Button (ACPI)
  └→ Record audio → faster-whisper STT → Ollama intent detection
        └→ Kodi JSON-RPC (play/pause/stop/…)  OR  Piper TTS answer
```

| Layer | Component |
|-------|-----------|
| Primary shell | Gamescope + Steam Gamepad UI (10-foot interface) |
| Media frontend | [Kodi](https://kodi.tv) via Kodi JSON-RPC HTTP API |
| Speech-to-text | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (Python venv, CPU) |
| Intent detection | [Ollama](https://ollama.com) — default model `mistral` |
| Text-to-speech | [Piper TTS](https://github.com/rhasspy/piper) + `en_US-lessac-medium` voice |
| Voice trigger | ACPI power-button event → `acpid` action |
| Emulation | Dolphin, RetroArch (added to Steam Gamepad UI) |
| Game streaming | Moonlight (NVIDIA GameStream / Sunshine) |

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
| `--llm-timeout N` | `60` | Seconds to wait for an LLM response (1–3600) |
| `--event 'STRING'` | `button/power.*` | Exact ACPI event match string |
| `--mic-device DEVICE` | `default` | ALSA capture device (e.g. `hw:1,0`) |
| `--speaker-device DEVICE` | `default` | ALSA playback device |
| `--tv-width W` | `3840` | TV output width (gamescope `-W`) |
| `--tv-height H` | `2160` | TV output height (gamescope `-H`) |
| `--render-width W` | `1920` | Internal render width (gamescope `-w`) |
| `--render-height H` | `1080` | Internal render height (gamescope `-h`) |
| `--framerate R` | `60` | Target frame rate (gamescope `-r`) |
| `--kodi-host HOST` | `localhost` | Kodi HTTP JSON-RPC hostname |
| `--kodi-port PORT` | `8080` | Kodi HTTP JSON-RPC port |
| `--kodi-user USER` | `kodi` | Kodi HTTP JSON-RPC username |
| `--kodi-pass PASS` | `KODI_PASS` env var | Kodi HTTP JSON-RPC password (Kodi ships with a default; change in Kodi → Settings → Services) |

Environment variables (`MODEL_NAME`, `RECORD_SECONDS`, `LLM_TIMEOUT`, `MIC_DEVICE`, `SPEAKER_DEVICE`, `TV_WIDTH`, `TV_HEIGHT`, `RENDER_WIDTH`, `RENDER_HEIGHT`, `FRAMERATE`, `KODI_HOST`, `KODI_PORT`, `KODI_USER`, `KODI_PASS`) are also honoured.

To pin the Piper binary to a specific version and verify its integrity:

```bash
PIPER_VERSION=2023.11.14-2 PIPER_SHA256=<sha256sum> sudo ./setup.sh
```

### Custom ACPI event

If `sudo acpi_listen` shows a different event string than `button/power.*`, re-run:

```bash
sudo ./setup.sh --event 'button/power PBTN 00000080 00000000'
```

> **Note:** re-running `setup.sh` overwrites the ACPI event file and autostart entry with the new (or default) values.

## What the Script Does

### Phase 0 — Foundation
0. **`familyman` user** — creates user, grants passwordless sudo, configures autologin (SDDM/GDM)
1. **System deps** — installs `acpid`, `alsa-utils`, `python3`, `piper`, etc. via `dnf`
   - **Optional HTPC packages** — attempts to install `steam`, `gamescope`, `kodi`, `dolphin-emu`, `retroarch`, `moonlight-qt`
2. **Ollama** — installs via official script, enables systemd service, pulls the chosen model
3. **faster-whisper venv** — creates `~/voice_assistant/venv`, installs `faster-whisper`, and **pre-downloads the Whisper `base` model** so the assistant runs fully offline after setup
4. **Piper TTS** — uses distro package if available; otherwise downloads a pinned release binary (see `PIPER_VERSION`) and the `en_US-lessac-medium` voice model from HuggingFace

### Phase 1 — Steam Gamepad UI shell (Step 10)
10. **Gamescope + Steam autostart** — writes `~/.config/autostart/steam-gaming.desktop` that launches `gamescope … -- steam -gamepadui` on login

### Phase 2 + 3 — Media + Voice (Steps 5 + 11)
5. **Voice pipeline** — deploys three files to `~/voice_assistant/`:
   - `intent_detect.py` — asks Ollama to classify a transcript as a media command or general question, returns structured JSON; uses a configurable timeout (see `--llm-timeout`) to prevent hanging
   - `kodi_search.py` — searches the Kodi library (TV shows + movies) and returns a `Player.Open` item parameter
   - `voice_trigger.sh` — orchestrates the pipeline: record → Whisper STT → intent detection → **Kodi JSON-RPC dispatch** (play/pause/stop/resume/next/previous/volume) or Piper TTS answer
11. **Kodi HTTP API** — writes `~/.kodi/userdata/advancedsettings.xml` enabling the JSON-RPC webserver on the configured port

   Voice commands (press front button, then speak):
   | Command | Effect |
   |---------|--------|
   | "Play Stargate Universe" | Searches Kodi library → plays first episode/movie |
   | "Pause" | Pauses current playback |
   | "Stop" | Stops current playback |
   | "Resume" | Resumes paused playback |
   | "Next" / "Previous" | Navigates playlist |
   | "Volume 50" | Sets Kodi volume to 50% |
   | Any question | Ollama answers, Piper speaks |

### Phase 4 — Performance tuning
Built into the gamescope autostart: renders at `--render-width × --render-height` internally (default 1920×1080) and scales to the TV at `--tv-width × --tv-height` (default 3840×2160). This keeps the UI smooth on the Vega M GL GPU.

### Phase 5 — Appliance mode (Step 12)
12. **Appliance mode** — three config files for a consumer-device feel:
    - `~/.config/autostart/disable-screen-blanking.desktop` — runs `xset dpms 0 0 0 && xset s off` on login
    - `~/.config/powermanagementprofilesrc` — disables all KDE sleep/suspend/screen-off actions
    - `~/.config/plasmanotifyrc` — suppresses KDE notifications in fullscreen

### Phase 6 — HTPC apps in Steam (Step 13)
13. **`htpc-add-steam-shortcuts`** — helper command that adds Kodi, Firefox, Dolphin Emulator, RetroArch, and Moonlight as non-Steam games in the Steam Gamepad UI

    Run **once** after logging in to Steam for the first time:
    ```bash
    htpc-add-steam-shortcuts
    # (use --dry-run to preview without writing)
    ```

### Infrastructure (Steps 6–9)
6. **Power button** — sets `HandlePowerKey=ignore` in `/etc/systemd/logind.conf` (backup saved as `.bak`) — warns before restarting `systemd-logind` as it will end the current session
7. **ACPI binding** — creates `/etc/acpi/events/nuc-voice-assistant` and `/etc/acpi/nuc-voice-assistant.sh` with `flock` (lock file in `/run/lock/`) to prevent overlapping invocations; checks that the user is logged in before starting the pipeline
8. **Test command** — installs `/usr/local/bin/nuc-voice-test`
9. **Log file** — initialises `/var/log/nuc-voice-assistant.log` (owned by `familyman`, mode 664) and appends a timestamped installation record

## Files Created / Modified

| Path | Description |
|------|-------------|
| `/etc/sudoers.d/familyman` | Passwordless sudo for `familyman` |
| `/etc/sddm.conf.d/autologin.conf` | SDDM autologin (or GDM `custom.conf`) |
| `~/voice_assistant/intent_detect.py` | Ollama intent classification helper |
| `~/voice_assistant/kodi_search.py` | Kodi library search helper |
| `~/voice_assistant/voice_trigger.sh` | Main STT→Intent→Kodi/TTS pipeline |
| `~/voice_assistant/venv/` | Python virtual environment |
| `~/voice_assistant/voices/` | Piper voice models |
| `~/voice_assistant/tmp/` | Private temp dir for audio/transcripts (mode 700) |
| `~/voice_assistant/bin/piper` | Piper binary (if not available via DNF) |
| `~/.config/autostart/steam-gaming.desktop` | Gamescope + Steam autostart |
| `~/.config/autostart/disable-screen-blanking.desktop` | xset DPMS-off autostart |
| `~/.kodi/userdata/advancedsettings.xml` | Kodi HTTP JSON-RPC configuration |
| `~/.config/powermanagementprofilesrc` | KDE no-sleep power profile |
| `~/.config/plasmanotifyrc` | KDE fullscreen notification suppression |
| `/etc/systemd/logind.conf` | `HandlePowerKey=ignore` (`.bak` backup) |
| `/etc/acpi/events/nuc-voice-assistant` | ACPI event rule |
| `/etc/acpi/nuc-voice-assistant.sh` | ACPI action script |
| `/usr/local/bin/nuc-voice-test` | Self-test command |
| `/usr/local/bin/htpc-add-steam-shortcuts` | Non-Steam apps helper |
| `/var/log/nuc-voice-assistant.log` | Timestamped log (owned by `familyman`) |

## After Setup

```bash
# 1. Enable Kodi HTTP remote control
#    Kodi → Settings → Services → Control → Allow remote control via HTTP
#    (port 8080, user kodi, pass kodi by default)

# 2. Add Kodi + other apps to the Steam Gamepad UI
htpc-add-steam-shortcuts

# 3. Run the full self-test
nuc-voice-test

# 4. Check services
systemctl status ollama
systemctl status acpid

# 5. Watch button events in real time
sudo acpi_listen

# 6. Tail the assistant log
sudo tail -f /var/log/nuc-voice-assistant.log
```

## Requirements

- Nobara Linux (Fedora-based, uses `dnf`)
- Internet access during setup (to download Ollama, the LLM model, the Piper voice, and the Whisper model)
- A microphone and speaker/headphone output
- Root access (`sudo`)
- Steam, gamescope, Kodi, and emulators — installed automatically if available in enabled repos; otherwise install via RPMFusion or Flatpak and re-run `setup.sh`

## Security Considerations

- **Passwordless sudo for `familyman`** — the script grants `familyman ALL=(ALL) NOPASSWD:ALL` for HTPC convenience (so the desktop user can manage the system without password prompts).  This is **not** required for the voice-assistant pipeline itself — `acpid` runs as root and calls `sudo -u familyman` directly, which does not need `familyman` to hold any sudo rights.  This broad grant is appropriate for a single-user kiosk, but on any shared or security-sensitive machine you should replace it with a minimal policy after setup:

  ```
  familyman ALL=(ALL) NOPASSWD: /home/familyman/voice_assistant/voice_trigger.sh
  ```

- **Ollama installer piped to `sh`** — `curl … | sh` is a common install pattern but carries supply-chain risk.  The comment in the script explains this; consider installing Ollama from a trusted package source first and then re-running `setup.sh`.

- **Piper binary checksum** — set `PIPER_SHA256` before running to verify the downloaded tarball:

  ```bash
  PIPER_VERSION=2023.11.14-2 PIPER_SHA256=<sha256sum> sudo ./setup.sh
  ```

- **Audio recordings** — captured WAV files are stored in `~/voice_assistant/tmp/` (mode 700) and deleted immediately after each run; transcripts follow the same lifecycle.

## Troubleshooting

**Power button press does nothing**

1. Check that `acpid` is running: `systemctl status acpid`
2. Capture the exact event string: `sudo acpi_listen` (then press the power button)
3. If it differs from `button/power.*`, re-run with: `sudo ./setup.sh --event '<paste line>'`

**"XDG_RUNTIME_DIR does not exist" in the log**

The `familyman` user must be logged in before the pipeline can produce audio.  Ensure autologin is enabled (the script configures SDDM or GDM) and that the user session has started.

**LLM response times out or is empty**

- Confirm the Ollama service is running: `systemctl status ollama`
- Test manually: `ollama run mistral "hello"` (substitute your model name)
- A slow first response on low-RAM hardware is normal; increase the timeout by re-running setup with `--llm-timeout 120`

**No audio output**

- Identify your ALSA device: `aplay -l`
- Re-run setup with the correct device: `sudo ./setup.sh --speaker-device hw:1,0`
- Test directly: `aplay -D hw:1,0 /path/to/test.wav`

**faster-whisper download fails behind a proxy**

Set `HTTP_PROXY` / `HTTPS_PROXY` before running `setup.sh`, or manually copy the Whisper model cache to `~/.cache/huggingface/hub/`.

**KDE / powerdevil overrides the power-button setting**

Navigate to *System Settings → Power Management → Advanced Power Settings* and set the power-button action to **Do nothing**.  The script will warn you if powerdevil is detected.

## Uninstall

The script does not provide an automatic uninstall, but the changes it makes are well-defined:

```bash
# Stop and disable services
sudo systemctl stop acpid
sudo systemctl disable acpid          # only if you didn't use acpid before setup

# Remove ACPI event and action files
sudo rm -f /etc/acpi/events/nuc-voice-assistant /etc/acpi/nuc-voice-assistant.sh
sudo systemctl restart acpid

# Restore logind power-button handling (prefer the backup written by setup.sh)
if [ -f /etc/systemd/logind.conf.bak ]; then
  sudo mv /etc/systemd/logind.conf.bak /etc/systemd/logind.conf
else
  sudo sed -i 's/^HandlePowerKey=ignore/HandlePowerKey=poweroff/' /etc/systemd/logind.conf
fi
sudo systemctl restart systemd-logind

# Remove sudoers file
sudo rm -f /etc/sudoers.d/familyman

# Remove autologin config (SDDM)
sudo rm -f /etc/sddm.conf.d/autologin.conf

# Remove the test command and shortcuts helper
sudo rm -f /usr/local/bin/nuc-voice-test /usr/local/bin/htpc-add-steam-shortcuts

# Remove the voice-assistant working directory
sudo rm -rf /home/familyman/voice_assistant

# Remove Steam/Kodi autostart and appliance-mode config
rm -f ~/.config/autostart/steam-gaming.desktop
rm -f ~/.config/autostart/disable-screen-blanking.desktop
rm -f ~/.config/powermanagementprofilesrc
rm -f ~/.config/plasmanotifyrc
rm -f ~/.kodi/userdata/advancedsettings.xml

# Optionally remove the familyman user
sudo userdel -r familyman

# Stop and uninstall Ollama (see https://github.com/ollama/ollama for instructions)
```

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
