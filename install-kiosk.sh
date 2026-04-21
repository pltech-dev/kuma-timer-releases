#!/usr/bin/env bash
# KUMA Timer — Raspberry Pi / Linux kiosk installer.
#
# Turns a fresh Raspberry Pi OS install into a dedicated KUMA Timer appliance:
#   - Copies the AppImage to /opt/kuma-timer/
#   - Installs a systemd user service that auto-starts KUMA on boot
#   - Hides the mouse cursor after 2 s of inactivity (unclutter-xfixes)
#   - Disables screen blanking so the timer stays visible 24/7
#   - Optionally configures auto-login and firewall rules
#
# Usage (run from the extracted release folder that contains this script +
# the .AppImage):
#
#   ./install-kiosk.sh                           # install for current user
#   sudo ./install-kiosk.sh --user pi            # install for user "pi"
#   sudo ./install-kiosk.sh --skip-autologin     # don't touch raspi-config
#   sudo ./install-kiosk.sh --skip-firewall      # don't touch ufw
#   sudo ./install-kiosk.sh --skip-unclutter     # keep mouse cursor visible
#   sudo ./install-kiosk.sh --enable-hotspot     # enable first-boot WiFi fallback (opt-in)
#   sudo ./install-kiosk.sh --quiet-boot         # silence kernel boot messages
#   ./install-kiosk.sh --uninstall               # remove everything
#
# Designed for Raspberry Pi OS Bookworm 64-bit. Works on Ubuntu/Debian too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="kuma-kiosk"
INSTALL_DIR="/opt/kuma-timer"
BIN_NAME="KUMA-Timer.AppImage"

ACTION="install"
# Prefer SUDO_USER (the real user when run via sudo), fall back to USER,
# then LOGNAME, then `id -un` as a last resort (all can be missing in
# minimal shells / Docker).
TARGET_USER="${SUDO_USER:-${USER:-${LOGNAME:-$(id -un)}}}"
SKIP_AUTOLOGIN=0
SKIP_FIREWALL=0
SKIP_UNCLUTTER=0
SKIP_HOTSPOT=1      # hotspot is opt-in — default skip to avoid hijacking wlan0
SKIP_QUIET_BOOT=1   # quiet boot touches /boot/firmware — opt-in only

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)        ACTION="uninstall"; shift ;;
        --user)             TARGET_USER="$2"; shift 2 ;;
        --skip-autologin)   SKIP_AUTOLOGIN=1; shift ;;
        --skip-firewall)    SKIP_FIREWALL=1; shift ;;
        --skip-unclutter)   SKIP_UNCLUTTER=1; shift ;;
        --skip-hotspot)     SKIP_HOTSPOT=1; shift ;;
        --enable-hotspot)   SKIP_HOTSPOT=0; shift ;;
        --quiet-boot)       SKIP_QUIET_BOOT=0; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

need_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "This step needs root. Re-run with sudo:  sudo $0 $*"
        exit 1
    fi
}

uninstall() {
    need_sudo "$@"
    echo "── Uninstalling KUMA kiosk ──"
    systemctl disable --now "${SERVICE_NAME}@${TARGET_USER}.service" 2>/dev/null || true
    systemctl disable --now kuma-wifi.service                        2>/dev/null || true
    systemctl disable --now kuma-iptables-restore.service            2>/dev/null || true
    # Tear down the hotspot connection if NetworkManager still has it
    if command -v nmcli >/dev/null; then
        nmcli connection delete KUMA-Hotspot 2>/dev/null || true
        nmcli connection delete KUMA-Client  2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/${SERVICE_NAME}@.service"
    rm -f /etc/systemd/system/kuma-wifi.service
    rm -f /etc/systemd/system/kuma-iptables-restore.service
    rm -f /etc/iptables/rules.v4
    rm -f /etc/sudoers.d/kuma-wifi
    rm -f "/home/$TARGET_USER/.config/autostart/kuma-unclutter.desktop"
    rm -f "/home/$TARGET_USER/.config/autostart/disable-screensaver.desktop"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    echo "Done. (autologin / firewall rules were not reverted; do that manually if needed.)"
    exit 0
}

[[ "$ACTION" == "uninstall" ]] && uninstall

# ── 1. Find the AppImage (same folder or dist/) ───────────────────────────────
APPIMAGE=""
for candidate in \
    "$SCRIPT_DIR"/*.AppImage \
    "$SCRIPT_DIR"/../../dist/*.AppImage \
    "$SCRIPT_DIR"/$BIN_NAME \
    "$SCRIPT_DIR"/../../../dist/*.AppImage
do
    if [[ -f "$candidate" ]]; then
        APPIMAGE="$candidate"
        break
    fi
done

if [[ -z "$APPIMAGE" ]]; then
    echo "ERROR: no .AppImage found near this script."
    echo "Place the downloaded KUMA Timer AppImage next to install-kiosk.sh"
    exit 1
fi

echo "── KUMA Timer kiosk installer ──"
echo "  AppImage:      $APPIMAGE"
echo "  Target user:   $TARGET_USER"
echo "  Install dir:   $INSTALL_DIR"
echo "  Options:       autologin=$([[ $SKIP_AUTOLOGIN -eq 1 ]] && echo skip || echo on)   firewall=$([[ $SKIP_FIREWALL -eq 1 ]] && echo skip || echo on)   unclutter=$([[ $SKIP_UNCLUTTER -eq 1 ]] && echo skip || echo on)   quiet-boot=$([[ $SKIP_QUIET_BOOT -eq 1 ]] && echo skip || echo on)"

# ── 2. Install AppImage ───────────────────────────────────────────────────────
need_sudo

mkdir -p "$INSTALL_DIR"
cp "$APPIMAGE" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"

# ── 3. Install systemd unit template (system-wide) ────────────────────────────
install -m 644 "$SCRIPT_DIR/kuma-kiosk.service" \
    "/etc/systemd/system/${SERVICE_NAME}@.service"

# Optional: copy the update helper alongside the AppImage
if [[ -f "$SCRIPT_DIR/update-kuma.sh" ]]; then
    install -m 755 "$SCRIPT_DIR/update-kuma.sh" "$INSTALL_DIR/update-kuma.sh"
fi

# WiFi hotspot onboarding scripts
if [[ $SKIP_HOTSPOT -eq 0 ]]; then
    for f in kuma-wifi-check.sh kuma-wifi-apply.sh kuma-wifi-scan.sh; do
        if [[ -f "$SCRIPT_DIR/$f" ]]; then
            install -m 755 "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
        fi
    done
    # systemd oneshot that detects no-network and brings up the hotspot
    if [[ -f "$SCRIPT_DIR/kuma-wifi.service" ]]; then
        install -m 644 "$SCRIPT_DIR/kuma-wifi.service" \
            /etc/systemd/system/kuma-wifi.service
    fi
    # sudoers rule — lets the kiosk user run the apply/scan scripts as root
    if [[ -f "$SCRIPT_DIR/kuma-wifi.sudoers" ]]; then
        sed "s/__USER__/$TARGET_USER/g" "$SCRIPT_DIR/kuma-wifi.sudoers" \
            > /etc/sudoers.d/kuma-wifi
        chmod 440 /etc/sudoers.d/kuma-wifi
        visudo -cf /etc/sudoers.d/kuma-wifi >/dev/null || {
            echo "     (warn) sudoers file invalid — removing"
            rm -f /etc/sudoers.d/kuma-wifi
        }
    fi
fi

# ── 4. Audio group — user needs it for LTC / sound ────────────────────────────
usermod -aG audio "$TARGET_USER" || true

# ── 5. Disable screen blanking (Raspberry Pi OS / Debian) ─────────────────────
if command -v raspi-config >/dev/null; then
    raspi-config nonint do_blanking 1 || true
fi
# Generic X11 fallback (for non-raspi-config systems)
mkdir -p "/home/$TARGET_USER/.config/autostart"
cat > "/home/$TARGET_USER/.config/autostart/disable-screensaver.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Screensaver
Exec=sh -c 'xset -dpms; xset s off; xset s noblank'
X-GNOME-Autostart-enabled=true
EOF

# ── 6. Hide mouse cursor on idle (unclutter-xfixes) ───────────────────────────
if [[ $SKIP_UNCLUTTER -eq 0 ]]; then
    echo "  → installing unclutter-xfixes (hides idle cursor)…"
    if ! command -v unclutter >/dev/null; then
        apt-get update -qq && apt-get install -y --no-install-recommends unclutter-xfixes || \
            echo "     (warn) unclutter-xfixes install failed — cursor will remain visible"
    fi
    cat > "/home/$TARGET_USER/.config/autostart/kuma-unclutter.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hide idle cursor
Exec=unclutter --timeout 2 --ignore-scrolling --fork
X-GNOME-Autostart-enabled=true
EOF
fi

chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.config/autostart"

# ── 7. Auto-login (Pi OS only — uses raspi-config) ────────────────────────────
if [[ $SKIP_AUTOLOGIN -eq 0 ]]; then
    if command -v raspi-config >/dev/null; then
        echo "  → configuring auto-login to desktop for user $TARGET_USER…"
        # B4 = Desktop autologin (X11 session starts automatically)
        raspi-config nonint do_boot_behaviour B4 || \
            echo "     (warn) could not set auto-login — set it manually with sudo raspi-config"
    else
        echo "  → auto-login skipped (raspi-config not available on this system)"
    fi
fi

# ── 8. Firewall rules (UFW) ───────────────────────────────────────────────────
if [[ $SKIP_FIREWALL -eq 0 ]] && command -v ufw >/dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo "  → opening UFW ports for KUMA services…"
        ufw allow 80/tcp   comment "KUMA admin panel"    || true
        ufw allow 5555/tcp comment "KUMA web controller" || true
        ufw allow 9000/udp comment "KUMA OSC input"      || true
        ufw allow 5353/udp comment "KUMA mDNS discovery" || true
        ufw allow 5960/udp comment "NDI mDNS"            || true
        ufw allow 5961:5990/tcp comment "NDI TCP range"  || true
    else
        echo "  → UFW is installed but inactive — skipping firewall rules"
    fi
fi

# ── 8b. Port 80 → 5555 (so http://<pi-ip>/ works with no port number) ─────────
# The Flask app binds :5555 (unprivileged). iptables PREROUTING redirects
# incoming :80 traffic to :5555 at the kernel level — no CAP_NET_BIND, no
# nginx/caddy, survives AppImage updates.
#
# Persistence: instead of relying on 'iptables-persistent' from apt (which
# silently fails on some Pi OS images and then leaves the reboot with no
# redirect — user gets a blank http://<ip>/), we ship our own tiny
# systemd oneshot that runs iptables-restore on every boot. Self-
# contained, zero apt dependencies, deterministic.
echo "  → setting up port 80 → 5555 redirect…"
# Remove any existing KUMA redirect rules before re-adding (idempotent)
while iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 5555 2>/dev/null; do
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 5555
done
while iptables -t nat -C OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 5555 2>/dev/null; do
    iptables -t nat -D OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 5555
done
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 5555
iptables -t nat -A OUTPUT     -p tcp -o lo --dport 80 -j REDIRECT --to-ports 5555
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Self-contained boot-time restore — no iptables-persistent required.
cat > /etc/systemd/system/kuma-iptables-restore.service <<'EOF'
[Unit]
Description=Restore KUMA iptables rules (port 80 → 5555 redirect)
Before=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable kuma-iptables-restore.service >/dev/null 2>&1 || \
    echo "     (warn) could not enable kuma-iptables-restore — :80 redirect won't survive reboot"

# ── 8c. Seed kiosk config (kiosk_mode=true, web_enabled=true, default pass) ──
# Creates the config file so the app starts in kiosk mode on first boot,
# with the web admin panel enabled and default credentials kuma/kuma.
CONFIG_FILE="/home/$TARGET_USER/.kumatimer_config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "  → seeding kiosk config ($CONFIG_FILE)…"
    cat > "$CONFIG_FILE" <<'EOF'
{
  "kiosk_mode": true,
  "web_enabled": true,
  "web_port": 5555,
  "web_control_password": "kuma"
}
EOF
    chown "$TARGET_USER:$TARGET_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
else
    echo "  → config exists, patching kiosk_mode=true (other fields preserved)…"
    # In-place update of just the kiosk/web fields, without touching the rest.
    python3 - <<PYEOF
import json, os
p = "$CONFIG_FILE"
try:
    with open(p) as f: cfg = json.load(f)
except Exception:
    cfg = {}
cfg["kiosk_mode"] = True
cfg.setdefault("web_enabled", True)
cfg.setdefault("web_port", 5555)
cfg.setdefault("web_control_password", "kuma")
with open(p, "w") as f: json.dump(cfg, f, indent=2)
PYEOF
    chown "$TARGET_USER:$TARGET_USER" "$CONFIG_FILE"
fi

# ── 9. Quiet boot (opt-in — modifies /boot/firmware/cmdline.txt) ──────────────
if [[ $SKIP_QUIET_BOOT -eq 0 ]]; then
    CMDLINE=""
    for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f "$candidate" ]] && CMDLINE="$candidate" && break
    done
    if [[ -n "$CMDLINE" ]]; then
        echo "  → enabling quiet boot via $CMDLINE…"
        cp "$CMDLINE" "$CMDLINE.bak-kuma"
        # Append quiet flags if not already present
        if ! grep -q '\bquiet\b' "$CMDLINE"; then
            sed -i 's|$| quiet splash loglevel=3 vt.global_cursor_default=0|' "$CMDLINE"
        fi
    else
        echo "  → (warn) quiet boot requested but no cmdline.txt found"
    fi
fi

# ── 10. Enable the services ───────────────────────────────────────────────────
systemctl daemon-reload
if [[ $SKIP_HOTSPOT -eq 0 ]] && [[ -f /etc/systemd/system/kuma-wifi.service ]]; then
    systemctl enable kuma-wifi.service
fi
systemctl enable --now "${SERVICE_NAME}@${TARGET_USER}.service"

echo ""
echo "✓ Kiosk mode installed."
echo ""
echo "  Service:   ${SERVICE_NAME}@${TARGET_USER}.service"
echo "  Status:    systemctl status ${SERVICE_NAME}@${TARGET_USER}"
echo "  Logs:      journalctl -u ${SERVICE_NAME}@${TARGET_USER} -f"
echo "  Stop:      sudo systemctl stop ${SERVICE_NAME}@${TARGET_USER}"
echo "  Restart:   sudo systemctl restart ${SERVICE_NAME}@${TARGET_USER}"
echo "  Update:    sudo $INSTALL_DIR/update-kuma.sh <path-to-new-AppImage>"
echo "  Uninstall: sudo $0 --uninstall --user $TARGET_USER"
echo ""
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "Remote access (from another device on the same network):"
echo "  - Admin panel:     http://$IP_ADDR/         (login: kuma / kuma)"
echo "  - OSC (UDP):       port 9000"
echo "  - NDI output:      'KUMA Timer' (auto-discovered via mDNS)"
echo ""
echo "First thing you should do after booting:"
echo "  1. Open http://$IP_ADDR/ on your laptop/tablet"
echo "  2. Login (kuma / kuma) and change the password under System"
echo ""
echo "Emergency exit from the kiosk (needs USB keyboard plugged into the Pi):"
echo "  Hold Ctrl+Alt+Q for 3 seconds — app quits and systemd restarts it"
echo "  in whichever mode is set in config (kiosk_mode=false → windowed)."
echo ""
echo "Reboot now?  sudo reboot"
