#!/bin/bash
# install_stage1.sh — installs max9296.ko + dtbo produced by build_stage1_oot.sh
#
# Usage:
#   ./scripts/install_stage1.sh              # install module + overlay, reboot required
#   ./scripts/install_stage1.sh --reload     # reload module only (no reboot, no overlay)
#   ./scripts/install_stage1.sh --restore    # restore the backup (undo a previous --reload)
#
# Run FROM the repo root on the Jetson (needs sudo).

set -e

MODE=${1:-full}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$REPO_ROOT/images/stage1"
KVER=$(uname -r)
TARGET=/lib/modules/$KVER/updates/drivers/media/i2c/max9296.ko
BACKUP=$TARGET.bak-stage1

MOD="$OUT/build/max9296.ko"
DTBO="$OUT/tegra234-camera-d4xx-overlay-max96712-lijag.dtbo"

# ---- --restore: revert to the backed-up module ----
if [[ "$MODE" == "--restore" ]]; then
    if [[ ! -f "$BACKUP" ]]; then
        echo "ERROR: no backup found at $BACKUP" >&2
        exit 1
    fi
    echo "=== Restoring backup max9296.ko ==="
    sudo rmmod d4xx 2>/dev/null || true
    sudo rmmod max9296 2>/dev/null || true
    sudo rmmod max9295 2>/dev/null || true
    sudo mv "$BACKUP" "$TARGET"
    sudo depmod -a
    sudo modprobe max9295
    sudo modprobe max9296
    sudo modprobe d4xx
    echo "=== Restored. Modules reloaded. ==="
    lsmod | grep -E 'max9|d4xx'
    exit 0
fi

if [[ ! -f "$MOD" ]]; then
    echo "ERROR: $MOD not found. Run ./scripts/build_stage1_oot.sh first." >&2
    exit 1
fi

echo "=== Module to install ==="
modinfo "$MOD" | grep -E '^filename|^vermagic'

# ---- Backup existing module (keep only the first backup — avoid overwriting it on re-runs) ----
if [[ -f "$TARGET" && ! -f "$BACKUP" ]]; then
    echo "=== Backing up existing module to $BACKUP ==="
    sudo cp "$TARGET" "$BACKUP"
fi

# ---- Hot reload (unload d4xx → max9296 → max9295, reload in reverse) ----
echo ""
echo "=== Unloading existing modules ==="
sudo rmmod d4xx 2>/dev/null || echo "(d4xx not loaded)"
sudo rmmod max9296 2>/dev/null || echo "(max9296 not loaded)"
sudo rmmod max9295 2>/dev/null || echo "(max9295 not loaded)"

echo "=== Installing new max9296.ko ==="
sudo cp "$MOD" "$TARGET"
sudo depmod -a

if [[ "$MODE" == "--reload" ]]; then
    echo "=== Reloading modules ==="
    # load one at a time so we can tell which fails
    if ! sudo modprobe max9295; then
        echo "ERROR: max9295 failed to load" >&2
        dmesg | tail -20
        exit 1
    fi
    if ! sudo modprobe max9296; then
        echo "ERROR: max9296 failed to load. Check dmesg. To restore: $0 --restore" >&2
        dmesg | tail -30
        exit 1
    fi
    if ! sudo modprobe d4xx; then
        echo "ERROR: d4xx failed to load. Check dmesg. To restore: $0 --restore" >&2
        dmesg | tail -30
        exit 1
    fi

    echo ""
    echo "=== Module status ==="
    lsmod | grep -E 'max9|d4xx'
    echo ""
    echo "=== dmesg since the reload (last 40 lines) ==="
    dmesg | tail -40
    echo ""
    echo "NOTE: DT overlay was NOT installed in --reload mode. If the DT still binds"
    echo "      max9296 to address 0x48 (MAX9296), our MAX96712 branches will NOT run."
    echo "      To install overlay + reboot, run: $0   (without --reload)"
    echo "      To undo this reload:              $0 --restore"
    exit 0
fi

# ---- Install DT overlay and require reboot ----
echo "=== Installing DT overlay ==="
sudo cp "$DTBO" /boot/
echo "Overlay at /boot/$(basename $DTBO)"

echo ""
echo "=== To activate the overlay, update /boot/extlinux/extlinux.conf ==="
echo "Add this line under your default entry:"
echo "    FDT /boot/$(basename $DTBO)"
echo ""
echo "Or use the Jetson-IO tool:"
echo "    sudo /opt/nvidia/jetson-io/jetson-io.py"
echo ""
echo "Then reboot with: sudo reboot"
