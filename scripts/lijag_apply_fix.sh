#!/bin/bash
# lijag_apply_fix.sh — apply a single new patch under nvidia-oot/6.2/ to the
# live sources_6.2 tree on the Orin, rebuild nvidia-oot incrementally, install
# the resulting max96712.ko (and max9296.ko if changed), depmod, and reboot.
#
# This is for the iterative LIJAG debug loop where we want to ship one
# additional patch (e.g. 0011-LIJAG-skip-reset-oneshot-in-set-pipe.patch)
# without re-running the full apply_patches.sh + build_all.sh path.
#
# Usage on Orin:
#   sudo ./scripts/lijag_apply_fix.sh <patch-name>
# Example:
#   sudo ./scripts/lijag_apply_fix.sh 0011-LIJAG-skip-reset-oneshot-in-set-pipe.patch
#
# Idempotent: if the patch already applied, it skips re-applying. If a build
# step is already up-to-date make is a no-op.

set -e

PATCH_NAME=${1:-}
if [[ -z "$PATCH_NAME" ]]; then
    echo "Usage: $0 <patch-name-under-nvidia-oot/6.2/>" >&2
    exit 2
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
JP=6.2
SRCS="$REPO_ROOT/sources_$JP"
PATCH_PATH="$REPO_ROOT/nvidia-oot/$JP/$PATCH_NAME"
OOT="$SRCS/nvidia-oot"
KVER=$(uname -r)

if [[ ! -f "$PATCH_PATH" ]]; then
    echo "ERROR: patch not found at $PATCH_PATH" >&2
    exit 1
fi
if [[ ! -d "$OOT" ]]; then
    echo "ERROR: nvidia-oot tree not found at $OOT" >&2
    echo "       Run ./apply_patches.sh $JP first." >&2
    exit 1
fi

echo "=== Applying $PATCH_NAME to $OOT ==="
cd "$OOT"
if git apply --check --reverse "$PATCH_PATH" 2>/dev/null; then
    echo "(patch already applied — skipping)"
else
    git apply --reject --whitespace=fix "$PATCH_PATH"
    echo "Patch applied."
fi

echo ""
echo "=== Rebuilding nvidia-oot modules (incremental) ==="
cd "$SRCS"
export KERNEL_HEADERS="$SRCS/kernel/kernel-jammy-src"
make modules

NEW_DSER=$OOT/drivers/media/i2c/max96712.ko
NEW_DSER_MAX9296=$OOT/drivers/media/i2c/max9296.ko
TARGET_DIR=/lib/modules/$KVER/updates/drivers/media/i2c

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "WARN: $TARGET_DIR does not exist; falling back to /lib/modules/$KVER/extra"
    TARGET_DIR=/lib/modules/$KVER/extra
fi

if [[ ! -f "$NEW_DSER" ]]; then
    echo "ERROR: $NEW_DSER not built" >&2
    exit 1
fi

echo ""
echo "=== Installing rebuilt modules to $TARGET_DIR ==="
TARGET_DSER=$(find /lib/modules/$KVER -name max96712.ko 2>/dev/null | head -1)
TARGET_MAX9296=$(find /lib/modules/$KVER -name max9296.ko 2>/dev/null | head -1)

if [[ -n "$TARGET_DSER" ]]; then
    echo "Installing max96712.ko -> $TARGET_DSER"
    cp "$NEW_DSER" "$TARGET_DSER"
else
    echo "Installing max96712.ko -> $TARGET_DIR/"
    install -D "$NEW_DSER" "$TARGET_DIR/max96712.ko"
fi
if [[ -f "$NEW_DSER_MAX9296" && -n "$TARGET_MAX9296" ]]; then
    echo "Installing max9296.ko -> $TARGET_MAX9296"
    cp "$NEW_DSER_MAX9296" "$TARGET_MAX9296"
fi

echo ""
echo "=== depmod ==="
depmod -a

echo ""
echo "=== Done. Reboot to apply ==="
echo "Run: sudo reboot"
echo ""
echo "(NOTE: if the MAX96712 was wedged before this fix it will likely still"
echo " require a full DC power cycle, not just a soft reboot, to recover."
echo " Pull the Jetson barrel jack and let it sit for ~5 s before powering on.)"
