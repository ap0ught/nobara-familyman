#!/usr/bin/env bash
# setup-magicmirror.sh — Idempotent MagicMirror² installer for Nobara HTPC
# Configures an Intel NUC8i7HNK as a fullscreen smart-mirror display for
# zip code 63021 (Ballwin, MO area).
#
# Usage:  sudo ./setup-magicmirror.sh [--user USERNAME] [--api-key KEY]
#                                     [--calendar-url URL]
#                                     [--location-id ID] [--location NAME]
#
# Re-running is safe — the script is fully idempotent.
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
HTPC_USER="familyman"
MM_REPO="https://github.com/MagicMirrorOrg/MagicMirror"
OPENWEATHER_API_KEY="${OPENWEATHER_API_KEY:-YOUR_API_KEY}"
CALENDAR_URL="${CALENDAR_URL:-YOUR_ICS_URL}"
# Ballwin, MO — OpenWeatherMap city ID for the 63021 zip-code area
LOCATION_ID="${LOCATION_ID:-4387778}"
LOCATION_NAME="${LOCATION_NAME:-Ballwin}"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)          HTPC_USER="$2";           shift 2 ;;
    --api-key)       OPENWEATHER_API_KEY="$2"; shift 2 ;;
    --calendar-url)  CALENDAR_URL="$2";        shift 2 ;;
    --location-id)   LOCATION_ID="$2";         shift 2 ;;
    --location)      LOCATION_NAME="$2";       shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Input validation ─────────────────────────────────────────────────────────
if ! [[ "$LOCATION_ID" =~ ^[0-9]+$ ]]; then
  echo "Error: --location-id must be a numeric OpenWeatherMap city ID." >&2
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[mm-setup] $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
  fi
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
require_root

if ! getent passwd "$HTPC_USER" &>/dev/null; then
  echo "Error: user '$HTPC_USER' does not exist. Run setup.sh first, or pass --user <name>." >&2
  exit 1
fi

REAL_HOME="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
MM_DIR="$REAL_HOME/MagicMirror"

log "Installing MagicMirror² for user : $HTPC_USER (home: $REAL_HOME)"
log "MagicMirror directory            : $MM_DIR"
log "Weather location                 : $LOCATION_NAME (ID: $LOCATION_ID)"

# ─── Step 1: System dependencies ─────────────────────────────────────────────
log "=== Step 1: System dependencies ==="

PKGS=(git curl nodejs npm)
if dnf info unclutter &>/dev/null; then
  PKGS+=(unclutter)
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

# Verify Node.js is present and functional
NODE_VER="$(node --version 2>/dev/null || echo '')"
NPM_VER="$(npm --version 2>/dev/null || echo '')"
if [[ -z "$NODE_VER" || -z "$NPM_VER" ]]; then
  echo "Error: node/npm not found after installation. Aborting." >&2
  exit 1
fi
ok "Node.js $NODE_VER / npm $NPM_VER"

# ─── Step 2: Clone / update MagicMirror² ─────────────────────────────────────
log "=== Step 2: MagicMirror² source ==="

if [[ ! -d "$MM_DIR/.git" ]]; then
  log "Cloning MagicMirror² into $MM_DIR ..."
  sudo -u "$HTPC_USER" git clone --depth=1 "$MM_REPO" "$MM_DIR"
  ok "Cloned MagicMirror²"
else
  log "Updating existing MagicMirror² repo..."
  sudo -u "$HTPC_USER" git -C "$MM_DIR" pull --ff-only || warn "git pull failed; continuing with existing version"
  ok "MagicMirror² repo up to date"
fi

# ─── Step 3: npm install ──────────────────────────────────────────────────────
log "=== Step 3: npm install ==="

# node_modules presence is a good-enough idempotency marker; re-run if absent.
if [[ ! -d "$MM_DIR/node_modules/electron" ]]; then
  log "Running npm install (this may take several minutes)..."
  sudo -u "$HTPC_USER" npm install --prefix "$MM_DIR"
  ok "npm install complete"
else
  ok "node_modules already present"
fi

# ─── Step 4: config/config.js ────────────────────────────────────────────────
log "=== Step 4: config/config.js ==="

CONFIG_FILE="$MM_DIR/config/config.js"

# Only write the config if it has not been customised already (i.e., still the
# sample, or absent entirely).  Use a sentinel comment to detect our config.
if grep -q 'MAGICMIRROR_SETUP_MANAGED' "$CONFIG_FILE" 2>/dev/null; then
  ok "config.js already managed by this script — skipping overwrite"
else
  log "Writing config.js for 63021 / $LOCATION_NAME ..."
  cat > "$CONFIG_FILE" << CONFIGEOF
/* config/config.js
 * MagicMirror² configuration for 63021 (${LOCATION_NAME}, MO)
 * MAGICMIRROR_SETUP_MANAGED — this file is written by setup-magicmirror.sh.
 * Edit freely; re-running the installer will NOT overwrite an existing file
 * that already contains the sentinel comment above.
 */

var config = {
  address: "localhost",
  port: 8080,
  basePath: "/",
  ipWhitelist: ["127.0.0.1", "::ffff:127.0.0.1", "::1"],

  useHttps: false,
  httpsPrivateKey: "",
  httpsCertificate: "",

  language: "en",
  locale: "en-US",
  logLevel: ["INFO", "LOG", "WARN", "ERROR"],
  timeFormat: 12,
  units: "imperial",

  modules: [

    // ── Clock ────────────────────────────────────────────────────────────────
    {
      module: "clock",
      position: "top_center",
      config: {
        timeFormat: 12,
        showDate: true,
        dateFormat: "dddd, MMMM D"
      }
    },

    // ── Current Weather — 63021 / ${LOCATION_NAME}, MO ───────────────────────
    {
      module: "weather",
      position: "top_right",
      config: {
        weatherProvider: "openweathermap",
        type: "current",
        location: "${LOCATION_NAME}",
        locationID: "${LOCATION_ID}",
        units: "imperial",
        apiKey: "${OPENWEATHER_API_KEY}"
      }
    },

    // ── Weather Forecast — 63021 / ${LOCATION_NAME}, MO ─────────────────────
    {
      module: "weather",
      position: "top_right",
      header: "Forecast",
      config: {
        weatherProvider: "openweathermap",
        type: "forecast",
        locationID: "${LOCATION_ID}",
        units: "imperial",
        apiKey: "${OPENWEATHER_API_KEY}"
      }
    },

    // ── Calendar ─────────────────────────────────────────────────────────────
    {
      module: "calendar",
      header: "Upcoming Events",
      position: "top_left",
      config: {
        calendars: [
          {
            symbol: "calendar-check",
            url: "${CALENDAR_URL}"
          }
        ]
      }
    },

    // ── News Feed ─────────────────────────────────────────────────────────────
    {
      module: "newsfeed",
      position: "bottom_bar",
      config: {
        feeds: [
          {
            title: "Reuters",
            url: "https://feeds.reuters.com/reuters/topNews"
          }
        ],
        showSourceTitle: true,
        showPublishDate: true,
        broadcastNewsFeeds: true,
        broadcastNewsUpdates: true
      }
    },

    // ── Compliments ──────────────────────────────────────────────────────────
    {
      module: "compliments",
      position: "lower_third"
    }

  ]
};

/*************** DO NOT EDIT THE LINE BELOW ***************/
if (typeof module !== "undefined") { module.exports = config; }
CONFIGEOF

  chown "$HTPC_USER:$(id -gn "$HTPC_USER")" "$CONFIG_FILE"
  ok "Wrote $CONFIG_FILE"
fi

# ─── Step 5: Fullscreen Electron start command ───────────────────────────────
log "=== Step 5: Fullscreen Electron mode ==="

PKG_JSON="$MM_DIR/package.json"

# Patch start script only if it doesn't already include --fullscreen
if grep -q '"start"' "$PKG_JSON" && ! grep -q -- '--fullscreen' "$PKG_JSON"; then
  # Use node to safely patch the JSON in-place
  sudo -u "$HTPC_USER" node - "$PKG_JSON" << 'NODEOF'
const fs   = require("fs");
const path = process.argv[2];
const pkg  = JSON.parse(fs.readFileSync(path, "utf8"));
if (pkg.scripts && pkg.scripts.start && !pkg.scripts.start.includes("--fullscreen")) {
  pkg.scripts.start = pkg.scripts.start.replace(
    /(\belectron\b.*?js\/electron\.js\b)/,
    "$1 --fullscreen --no-sandbox"
  );
  fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n", "utf8");
  process.stdout.write("  patched\n");
} else {
  process.stdout.write("  already patched or start script not found\n");
}
NODEOF
  ok "package.json start script patched for fullscreen"
else
  ok "package.json already contains --fullscreen flag"
fi

# ─── Step 6: KDE autostart — MagicMirror² ────────────────────────────────────
log "=== Step 6: KDE autostart entries ==="

AUTOSTART_DIR="$REAL_HOME/.config/autostart"
install -d -o "$HTPC_USER" -g "$(id -gn "$HTPC_USER")" "$AUTOSTART_DIR"

MM_DESKTOP="$AUTOSTART_DIR/magicmirror.desktop"
cat > "$MM_DESKTOP" << DESKTOPEOF
[Desktop Entry]
Type=Application
Name=MagicMirror
Exec=/usr/bin/npm start --prefix ${MM_DIR}
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DESKTOPEOF
chown "$HTPC_USER:$(id -gn "$HTPC_USER")" "$MM_DESKTOP"
chmod 644 "$MM_DESKTOP"
ok "Wrote $MM_DESKTOP"

# Cursor hiding (requires unclutter)
if command -v unclutter &>/dev/null; then
  UNCLUTTER_DESKTOP="$AUTOSTART_DIR/unclutter.desktop"
  cat > "$UNCLUTTER_DESKTOP" << UNCEOF
[Desktop Entry]
Type=Application
Name=Hide cursor (unclutter)
Exec=/usr/bin/unclutter -idle 0
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
UNCEOF
  chown "$HTPC_USER:$(id -gn "$HTPC_USER")" "$UNCLUTTER_DESKTOP"
  chmod 644 "$UNCLUTTER_DESKTOP"
  ok "Wrote $UNCLUTTER_DESKTOP"
else
  warn "unclutter not found; cursor hiding autostart entry skipped."
fi

# Screen-blanking prevention via xset
XSET_DESKTOP="$AUTOSTART_DIR/disable-screensaver.desktop"
cat > "$XSET_DESKTOP" << XSETEOF
[Desktop Entry]
Type=Application
Name=Disable screensaver
Exec=/bin/bash -c "xset s off && xset s noblank && xset -dpms"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
XSETEOF
chown "$HTPC_USER:$(id -gn "$HTPC_USER")" "$XSET_DESKTOP"
chmod 644 "$XSET_DESKTOP"
ok "Wrote $XSET_DESKTOP"

# ─── Verification summary ─────────────────────────────────────────────────────
echo ""
echo "=== MagicMirror² Setup Complete — 63021 / ${LOCATION_NAME} ==="
echo ""
echo " MagicMirror² installed in: ${MM_DIR}"
echo ""
echo " ➜  Edit your API key and calendar URL in the config:"
echo "      nano ${CONFIG_FILE}"
echo ""
echo "    Replace:"
echo "      apiKey: \"YOUR_API_KEY\"   →  your OpenWeatherMap API key"
echo "      url: \"YOUR_ICS_URL\"      →  your Google/iCal .ics URL"
echo ""
echo " ➜  Get a free OpenWeatherMap API key at:"
echo "      https://openweathermap.org/api"
echo ""
echo " ➜  Test the mirror manually (as ${HTPC_USER}):"
echo "      sudo -u ${HTPC_USER} npm start --prefix ${MM_DIR}"
echo ""
echo " ➜  On next login, MagicMirror² will start automatically fullscreen."
echo ""
echo " ➜  Dual-mode tip: create a second user account or boot script to"
echo "      switch between Steam HTPC mode and MagicMirror mode."
echo ""
