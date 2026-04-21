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

GH_API="https://api.github.com/repos/pltech-dev/kuma-timer-releases"
GH_DL="https://github.com/pltech-dev/kuma-timer-releases/releases/download"
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

# ── Package names vary across Pi OS / Debian releases:
#   Bookworm (original):  libfuse2       libfuse3-3  fuse3
#   Bookworm (t64 ABI):   libfuse2t64    libfuse3t64 fuse3
#   Trixie:               libfuse2t64    libfuse3-4  fuse3
# apt auto-aliases libfuse2 → libfuse2t64 (friendly), but libfuse3-3 hard-
# fails on systems that shipped libfuse3-4 or libfuse3t64. We resolve the
# fuse3 package name dynamically and only mark libfuse2 as critical —
# AppImage v2 runtime loads libfuse2; libfuse3 is only used by some tools.
_fuse3_pkg=""
for _p in libfuse3-3 libfuse3t64 libfuse3-4; do
  if apt-cache show "$_p" >/dev/null 2>&1; then _fuse3_pkg="$_p"; break; fi
done

# libportaudio2  — sounddevice dlopens it at startup; missing = kiosk
#                  restart-loop with "PortAudio library not found".
# libfuse2       — AppImage v2 mount runtime.
# Do NOT silence stderr: a missing critical lib must fail loudly so
# we don't hand the user a Pi that silently doesn't work.
echo "  → critical libs (libportaudio2, libfuse2, curl, ca-certificates)…"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl libfuse2 ca-certificates libportaudio2; then
  echo "ERROR: failed to install critical dependencies via apt."
  echo "       Check apt sources (/etc/apt/sources.list.d/), then retry."
  exit 1
fi

# Optional: fuse3 stack (nicer AppImage startup on some distros) +
# kiosk niceties. Never blocks install — we warn and move on.
echo "  → optional libs (fuse3, ufw, unclutter-xfixes)…"
_optional=(ufw unclutter-xfixes fuse3)
[[ -n "$_fuse3_pkg" ]] && _optional+=("$_fuse3_pkg")
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${_optional[@]}" >/dev/null 2>&1 || \
    echo "     (warn) some optional packages failed to install — continuing"

# ── Download ──────────────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t kuma-install-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

# Find the most-recently-published release (including pre-releases).
# /releases/latest skips pre-releases → breaks installs when only rc
# builds exist. The /releases list endpoint doesn't sort by date, it
# sorts by release-object ID (creation order of the RELEASE entity,
# which can be older than the tag it points to if the release object
# was created-then-updated). We fetch a window of recent releases and
# pick the one with the newest published_at — the author's intent.
# Python 3 ships with Pi OS Bookworm, so we use it (jq isn't default).
echo "→ Looking up latest release tag…"
LATEST_TAG="$(curl -fsSL "$GH_API/releases?per_page=15" \
  | python3 -c 'import json, sys; rel=json.load(sys.stdin); print(sorted(rel, key=lambda r: r["published_at"], reverse=True)[0]["tag_name"])' \
  2>/dev/null || true)"
if [[ -z "$LATEST_TAG" ]]; then
  echo "ERROR: couldn't resolve latest release tag from $GH_API"
  echo "       Check your internet connection, then try again."
  exit 1
fi
echo "  → $LATEST_TAG"

RELEASE_DL="$GH_DL/$LATEST_TAG"

echo "→ Downloading AppImage ($LATEST_TAG)…"
if ! curl -fL --retry 3 --retry-delay 2 -o "$APPIMAGE_NAME" \
        "$RELEASE_DL/$APPIMAGE_NAME"; then
  echo "ERROR: failed to download AppImage from $RELEASE_DL/$APPIMAGE_NAME"
  echo "       Check your internet connection, then try again."
  exit 1
fi
chmod +x "$APPIMAGE_NAME"

echo "→ Downloading kiosk scripts (from main branch — latest fixes)…"
# Kiosk installer scripts live on the kuma-timer-releases main branch,
# NOT as release assets. This decouples script bug-fixes from AppImage
# rebuilds — a kiosk-side regression can be patched in minutes via a
# single git commit, without tagging a new release. The AppImage itself
# is always pinned to a specific release tag (above).
RAW_BASE="https://raw.githubusercontent.com/pltech-dev/kuma-timer-releases/main"
KIOSK_FILES=(
    install-kiosk.sh
    kuma-kiosk.service
    update-kuma.sh
)
for f in "${KIOSK_FILES[@]}"; do
  if ! curl -fL --retry 3 --retry-delay 2 -o "$f" "$RAW_BASE/$f"; then
    echo "ERROR: failed to download $f from $RAW_BASE/$f"
    exit 1
  fi
done
chmod +x install-kiosk.sh update-kuma.sh

# ── Run kiosk installer ──────────────────────────────────────────────────────

echo ""
echo "→ Running kiosk installer…"
echo ""
./install-kiosk.sh --user "$TARGET_USER" --skip-hotspot

# ── Post-install health check ─────────────────────────────────────────────────
# `systemctl enable --now kuma-kiosk@USER.service` returns 0 if the unit got
# enabled AND systemd successfully forked the process, EVEN IF that process
# immediately exits with an error (systemd then enters a restart loop). So we
# have to actively verify the service is running, not just "enabled".
# Wait up to 20 s, checking once per second — long enough to absorb the
# normal start-up time plus two restart attempts (Restart=always, RestartSec=2).
echo ""
echo "→ Verifying kiosk service actually started…"
_SERVICE="kuma-kiosk@${TARGET_USER}.service"
_HEALTHY=0
for _i in $(seq 1 20); do
    # "active (running)" OR "active (exited)" both OK; "activating (auto-restart)"
    # or "failed" mean the unit is crash-looping or gave up.
    if systemctl is-active --quiet "$_SERVICE"; then
        _HEALTHY=1
        break
    fi
    sleep 1
done

if [[ $_HEALTHY -eq 0 ]]; then
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  ✗ KUMA kiosk service failed to start cleanly"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    echo "  The installer completed, but the service keeps crashing."
    echo "  Most recent logs:"
    echo ""
    journalctl -u "$_SERVICE" -n 20 --no-pager --no-hostname 2>/dev/null \
        | sed 's/^/    /'
    echo ""
    echo "  Full diagnostics: sudo journalctl -u $_SERVICE -n 200 --no-pager"
    echo "  Retry install:   curl -fsSL https://raw.githubusercontent.com/pltech-dev/kuma-timer-releases/main/install-pi.sh | sudo bash"
    exit 1
fi

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
