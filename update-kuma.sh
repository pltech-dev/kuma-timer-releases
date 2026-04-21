#!/usr/bin/env bash
# KUMA Timer — kiosk update helper.
#
# Stops the running kiosk, replaces the AppImage, and starts it again.
# Keeps the previous AppImage as .bak so you can roll back if the new build
# doesn't start.
#
# Usage:
#   sudo /opt/kuma-timer/update-kuma.sh                       # auto: latest release
#   sudo /opt/kuma-timer/update-kuma.sh <path-to-new-AppImage>
#   sudo /opt/kuma-timer/update-kuma.sh <URL-of-new-AppImage>
#
# With no argument the script resolves the newest release on
# pltech-dev/kuma-timer-releases (pre-releases included) and downloads
# its aarch64 AppImage. This is what the web-admin "Update now" button
# calls.

set -euo pipefail

INSTALL_DIR="/opt/kuma-timer"
BIN_NAME="KUMA-Timer.AppImage"
SERVICE_NAME="kuma-kiosk"
GH_API="https://api.github.com/repos/pltech-dev/kuma-timer-releases"
GH_DL="https://github.com/pltech-dev/kuma-timer-releases/releases/download"
APPIMAGE_ASSET="KUMA-Timer-linux-aarch64.AppImage"

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must run as root.  sudo $0 $*"
    exit 1
fi

if [[ $# -ge 1 ]]; then
    SOURCE="$1"
else
    # Auto-resolve latest release (including pre-releases). GitHub's
    # /releases/latest endpoint skips pre-releases, so we use the list
    # endpoint + python3 to sort by published_at. Python 3 ships with
    # Pi OS Bookworm so no extra deps.
    echo "→ Looking up latest KUMA release…"
    LATEST_TAG="$(curl -fsSL "$GH_API/releases?per_page=15" \
      | python3 -c 'import json, sys; rel=json.load(sys.stdin); print(sorted(rel, key=lambda r: r["published_at"], reverse=True)[0]["tag_name"])' \
      2>/dev/null || true)"
    if [[ -z "$LATEST_TAG" ]]; then
        echo "ERROR: couldn't resolve latest release tag from GitHub."
        echo "       Check internet connectivity, or pass a URL/path explicitly."
        exit 1
    fi
    echo "  → $LATEST_TAG"
    SOURCE="$GH_DL/$LATEST_TAG/$APPIMAGE_ASSET"
fi

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
