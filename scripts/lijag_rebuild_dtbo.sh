#!/bin/bash
# lijag_rebuild_dtbo.sh — rebuild ONLY the LI-JAG MAX96712 dtbo
# (no kernel, no modules) and install it under /boot/.
#
# Use this when iterating on the LI-JAG DT overlay without changing any
# kernel sources. After running this, run "sudo reboot" to pick up the
# new overlay (extlinux.conf already points to it from
# enable_max96712_overlay.sh).
#
# Usage on Orin:
#   sudo ./scripts/lijag_rebuild_dtbo.sh

set -e

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
JP=6.2
SRCS="$REPO_ROOT/sources_$JP"
OUT="$REPO_ROOT/images/stage1"

OVERLAY_SRC="$REPO_ROOT/hardware/realsense/tegra234-camera-d4xx-overlay-max96712-lijag.dts"
OVERLAY_DTBO="$OUT/tegra234-camera-d4xx-overlay-max96712-lijag.dtbo"
DTBO_NAME=$(basename "$OVERLAY_DTBO")

if [[ ! -f "$OVERLAY_SRC" ]]; then
    echo "ERROR: $OVERLAY_SRC not found" >&2
    exit 1
fi
if [[ ! -d "$SRCS/hardware/nvidia/t23x" ]]; then
    echo "ERROR: $SRCS/hardware/nvidia/t23x not found — run apply_patches.sh first" >&2
    exit 1
fi

mkdir -p "$OUT"

echo "=== Preprocessing $OVERLAY_SRC ==="
cpp -nostdinc -undef -x assembler-with-cpp \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include" \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include/platforms" \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include/kernel" \
    -I"$SRCS/kernel/kernel-jammy-src/include" \
    -I"$SRCS/kernel/kernel-jammy-src/scripts/dtc/include-prefixes" \
    "$OVERLAY_SRC" -o "$OUT/overlay.dts.pp"

echo "=== Compiling dtbo ==="
dtc -@ -I dts -O dtb -o "$OVERLAY_DTBO" "$OUT/overlay.dts.pp"
echo "Built: $OVERLAY_DTBO ($(stat -c%s "$OVERLAY_DTBO") bytes)"

echo ""
echo "=== Installing to /boot ==="
cp "$OVERLAY_DTBO" "/boot/$DTBO_NAME"
ls -la "/boot/$DTBO_NAME"

echo ""
echo "=== Done ==="
echo "extlinux.conf already points at /boot/$DTBO_NAME (set by enable_max96712_overlay.sh)."
echo "Reboot to pick up the new overlay:"
echo "    sudo reboot"
