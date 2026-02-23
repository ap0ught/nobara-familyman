# nobara-familyman

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
| `--kodi-pass PASS` | `kodi` | Kodi HTTP JSON-RPC password |

Environment variables (`MODEL_NAME`, `RECORD_SECONDS`, `MIC_DEVICE`, `SPEAKER_DEVICE`, `TV_WIDTH`, `TV_HEIGHT`, `RENDER_WIDTH`, `RENDER_HEIGHT`, `FRAMERATE`, `KODI_HOST`, `KODI_PORT`, `KODI_USER`, `KODI_PASS`) are also honoured.

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
   - `intent_detect.py` — asks Ollama to classify a transcript as a media command or general question, returns structured JSON
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
6. **Power button** — sets `HandlePowerKey=ignore` in `/etc/systemd/logind.conf`
7. **ACPI binding** — `/etc/acpi/events/nuc-voice-assistant` + `/etc/acpi/nuc-voice-assistant.sh` with `flock` guard
8. **Test command** — `/usr/local/bin/nuc-voice-test`
9. **Log file** — `/var/log/nuc-voice-assistant.log`

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
