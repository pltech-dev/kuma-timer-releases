#!/usr/bin/env bash
# KUMA Timer — one-line Raspberry Pi installer.
#
# Usage (on a fresh Raspberry Pi OS 64-bit install):
#
#   curl -fsSL https://kuma.pl-tech.co.uk/install-pi.sh | sudo bash
#
# What it does:
#   1. Downloads the latest KUMA Timer AppImage from the public releases repo
#   2. Downloads kiosk scripts (install-kiosk.sh, systemd units, WiFi onboarding)
#   3. Runs install-kiosk.sh → auto-start on boot, fullscreen, no cursor
#   4. Prompts for reboot
#
# Tested on: Raspberry Pi 4 / 5 with Pi OS Bookworm 64-bit.

set -euo pipefail

BASE_WEB="https://kuma.pl-tech.co.uk/kiosk"
RELEASES="https://github.com/pltech-dev/kuma-timer-releases/releases/latest/download"
APPIMAGE_NAME="KUMA-Timer-linux-aarch64.AppImage"

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo "This installer needs root. Run:"
  echo "  curl -fsSL https://kuma.pl-tech.co.uk/install-pi.sh | sudo bash"
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  echo "ERROR: This installer is for ARM64/aarch64 (Raspberry Pi 4/5 64-bit)."
  echo "       Detected architecture: $ARCH"
  echo ""
  echo "If you're on Mac/Windows/Intel Linux, download KUMA from:"
  echo "  https://kuma.pl-tech.co.uk/"
  exit 1
fi

# Figure out the target user — SUDO_USER when invoked via sudo,
# else the only non-system user, else 'pi' as fallback.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print $1; exit }')"
fi
TARGET_USER="${TARGET_USER:-pi}"

if ! id "$TARGET_USER" &>/dev/null; then
  echo "ERROR: User '$TARGET_USER' not found."
  echo "       Create a regular user first (e.g. via Pi Imager advanced options)."
  exit 1
fi

echo "══════════════════════════════════════════════════════════════"
echo "  KUMA Timer — Raspberry Pi installer"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Target user:   $TARGET_USER"
echo "  Architecture:  $ARCH"
echo ""

# ── Dependencies ──────────────────────────────────────────────────────────────

echo "→ Installing dependencies (curl, libfuse, libportaudio2, unclutter)…"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
# libportaudio2  — sounddevice (LTC input) dlopens it at startup, not
#                  bundled in the AppImage.
# python3-pyqt6.qtsvg — kept for consistency with build-time deps even
#                  though PyInstaller freezes its own PyQt6; harmless.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl libfuse2 libfuse3-3 fuse3 unclutter-xfixes ufw ca-certificates \
    libportaudio2 \
    >/dev/null 2>&1 || true

# ── Download ──────────────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t kuma-install-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

echo "→ Downloading latest AppImage from GitHub releases…"
if ! curl -fL --retry 3 --retry-delay 2 -o "$APPIMAGE_NAME" \
        "$RELEASES/$APPIMAGE_NAME"; then
  echo "ERROR: failed to download AppImage from $RELEASES/$APPIMAGE_NAME"
  echo "       Check your internet connection, then try again."
  exit 1
fi
chmod +x "$APPIMAGE_NAME"

echo "→ Downloading kiosk scripts…"
KIOSK_FILES=(
    install-kiosk.sh
    kuma-kiosk.service
    update-kuma.sh
)
for f in "${KIOSK_FILES[@]}"; do
  if ! curl -fL --retry 3 --retry-delay 2 -o "$f" "$BASE_WEB/$f"; then
    echo "ERROR: failed to download $f from $BASE_WEB/$f"
    exit 1
  fi
done
chmod +x install-kiosk.sh update-kuma.sh

# ── Run kiosk installer ──────────────────────────────────────────────────────

echo ""
echo "→ Running kiosk installer…"
echo ""
./install-kiosk.sh --user "$TARGET_USER" --skip-hotspot

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ✓ KUMA Timer installed in kiosk mode"
echo "══════════════════════════════════════════════════════════════"
echo ""
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "  Admin panel (from any device on the same WiFi):"
echo "    http://$IP_ADDR/         (login: kuma / kuma — change in System tab)"
echo ""
echo "  Update later:   sudo /opt/kuma-timer/update-kuma.sh"
echo "  Uninstall:      sudo /opt/kuma-timer/install-kiosk.sh --uninstall --user $TARGET_USER"
echo ""
echo "  Emergency exit from kiosk (USB keyboard plugged into Pi):"
echo "    hold Ctrl+Alt+Q for 3 seconds"
echo ""

if [[ -t 0 ]]; then
  read -r -p "Reboot now? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] && reboot
else
  echo "Reboot with:  sudo reboot"
fi
