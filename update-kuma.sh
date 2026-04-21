#!/usr/bin/env bash
# KUMA Timer — kiosk update helper.
#
# Stops the running kiosk, replaces the AppImage, and starts it again.
# Keeps the previous AppImage as .bak so you can roll back if the new build
# doesn't start.
#
# Usage:
#   sudo /opt/kuma-timer/update-kuma.sh <path-to-new-AppImage>
#
# Examples:
#   # Update from a local download
#   sudo /opt/kuma-timer/update-kuma.sh ~/Downloads/KUMA-Timer-1.8.1-aarch64.AppImage
#
#   # Update directly from a URL
#   sudo /opt/kuma-timer/update-kuma.sh https://kuma.pl-tech.co.uk/downloads/v1.8.1/KUMA-Timer-1.8.1-aarch64.AppImage

set -euo pipefail

INSTALL_DIR="/opt/kuma-timer"
BIN_NAME="KUMA-Timer.AppImage"
SERVICE_NAME="kuma-kiosk"

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must run as root.  sudo $0 $*"
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage:  sudo $0 <path-or-URL-of-new-AppImage>"
    exit 1
fi

SOURCE="$1"

# Resolve the currently-running user's kiosk service (there's exactly one instance)
ACTIVE_SVC="$(systemctl list-units --type=service --state=active --plain --no-legend 2>/dev/null \
    | awk -v svc="$SERVICE_NAME" '$1 ~ "^"svc"@" {print $1; exit}')"

if [[ -z "$ACTIVE_SVC" ]]; then
    echo "(warning) no running ${SERVICE_NAME}@... service found — will still swap binary"
fi

# ── 1. Fetch the new AppImage into a temp location ────────────────────────────
TMP="$(mktemp -t kuma-update-XXXXXX.AppImage)"
trap 'rm -f "$TMP"' EXIT

if [[ "$SOURCE" =~ ^https?:// ]]; then
    echo "Downloading  $SOURCE"
    curl -fL --progress-bar -o "$TMP" "$SOURCE"
else
    if [[ ! -f "$SOURCE" ]]; then
        echo "ERROR: file not found: $SOURCE"
        exit 1
    fi
    cp "$SOURCE" "$TMP"
fi

# Sanity check — must be an AppImage
if ! file "$TMP" | grep -qE 'ELF.*executable'; then
    echo "ERROR: downloaded file is not an ELF executable."
    file "$TMP"
    exit 1
fi
chmod +x "$TMP"

# ── 2. Stop the service (if running) ──────────────────────────────────────────
if [[ -n "$ACTIVE_SVC" ]]; then
    echo "Stopping  $ACTIVE_SVC"
    systemctl stop "$ACTIVE_SVC"
fi

# ── 3. Swap with rollback-friendly .bak ───────────────────────────────────────
if [[ -f "$INSTALL_DIR/$BIN_NAME" ]]; then
    mv "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME.bak"
fi
mv "$TMP" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
chown "$(stat -c %U "$INSTALL_DIR")":"$(stat -c %G "$INSTALL_DIR")" "$INSTALL_DIR/$BIN_NAME"

# ── 4. Restart ────────────────────────────────────────────────────────────────
if [[ -n "$ACTIVE_SVC" ]]; then
    echo "Starting  $ACTIVE_SVC"
    systemctl start "$ACTIVE_SVC"

    # Quick health check — service should be active within 5 s
    sleep 5
    if ! systemctl is-active --quiet "$ACTIVE_SVC"; then
        echo "── UPDATE FAILED: service did not come up. Rolling back. ──"
        mv "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME.broken"
        mv "$INSTALL_DIR/$BIN_NAME.bak" "$INSTALL_DIR/$BIN_NAME"
        systemctl start "$ACTIVE_SVC"
        echo "Restored previous AppImage. The failing build is at $INSTALL_DIR/$BIN_NAME.broken"
        exit 1
    fi
fi

echo ""
echo "✓ KUMA Timer updated."
echo "  Previous version kept at:  $INSTALL_DIR/$BIN_NAME.bak"
echo "  Rollback (if needed):      sudo $0 $INSTALL_DIR/$BIN_NAME.bak"
