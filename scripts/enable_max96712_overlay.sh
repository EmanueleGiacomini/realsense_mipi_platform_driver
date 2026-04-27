#!/bin/bash
# enable_max96712_overlay.sh — installs the MAX96712 DT overlay and updates
# the JetsonIO boot entry in /boot/extlinux/extlinux.conf.
#
# Safety: backs up extlinux.conf, shows the diff, asks for confirmation before
# committing. The `primary` entry is left untouched as a fallback — if boot
# fails with MAX96712, interrupt the 30s timeout and select `primary`.
#
# Usage:
#   ./scripts/enable_max96712_overlay.sh            # install + confirm + edit
#   ./scripts/enable_max96712_overlay.sh --revert   # restore extlinux.conf backup
#
# Run FROM the repo root on the Jetson (needs sudo).

set -e

MODE=${1:-install}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$REPO_ROOT/images/stage1"
DTBO="$OUT/tegra234-camera-d4xx-overlay-max96712-lijag.dtbo"
DTBO_NAME=$(basename "$DTBO")

EXTLINUX=/boot/extlinux/extlinux.conf
EXTLINUX_BAK=/boot/extlinux/extlinux.conf.bak-before-max96712

if [[ "$MODE" == "--revert" ]]; then
    if [[ ! -f "$EXTLINUX_BAK" ]]; then
        echo "ERROR: no backup at $EXTLINUX_BAK" >&2
        exit 1
    fi
    echo "=== Reverting $EXTLINUX to $EXTLINUX_BAK ==="
    sudo cp "$EXTLINUX_BAK" "$EXTLINUX"
    echo "Reverted. Old overlay reference restored. Reboot to pick it up."
    exit 0
fi

if [[ ! -f "$DTBO" ]]; then
    echo "ERROR: $DTBO not found. Run build_stage1_oot.sh first." >&2
    exit 1
fi

# 1. Copy overlay to /boot
echo "=== Copying overlay to /boot ==="
sudo cp "$DTBO" "/boot/$DTBO_NAME"
ls -la "/boot/$DTBO_NAME"

# 2. Backup extlinux.conf if we haven't already
if [[ ! -f "$EXTLINUX_BAK" ]]; then
    echo "=== Backing up extlinux.conf to $EXTLINUX_BAK ==="
    sudo cp "$EXTLINUX" "$EXTLINUX_BAK"
fi

# 3. Edit ONLY the JetsonIO section's OVERLAYS line. Use awk for block-aware
# substitution so the `primary` entry stays untouched.
TMP=$(mktemp)
sudo awk -v new_overlay="/boot/$DTBO_NAME" '
    /^LABEL[ \t]/ { in_jetsonio = ($2 == "JetsonIO") }
    in_jetsonio && /^[ \t]*OVERLAYS[ \t]/ {
        # Replace the first whitespace-separated path with the new one
        sub(/\/boot\/[^ \t\n]*\.dtbo/, new_overlay)
    }
    { print }
' "$EXTLINUX" > "$TMP"

# Sanity check: did it actually make a change?
if diff -q "$EXTLINUX" "$TMP" > /dev/null 2>&1; then
    echo "WARNING: awk produced no changes. The JetsonIO OVERLAYS line may"
    echo "         already point to $DTBO_NAME, or the extlinux.conf format"
    echo "         does not match what the script expects."
    echo ""
    echo "=== Current JetsonIO entry ==="
    sudo awk '/^LABEL[ \t]/ { p = ($2 == "JetsonIO") } p' "$EXTLINUX"
    rm -f "$TMP"
    exit 1
fi

# 4. Show the diff
echo ""
echo "=== Proposed change (old -> new) ==="
diff -u "$EXTLINUX" "$TMP" || true
echo ""

# 5. Confirm
read -p "Apply this change? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    rm -f "$TMP"
    echo "Aborted. No changes made (backup at $EXTLINUX_BAK remains)."
    exit 1
fi

# 6. Install
sudo cp "$TMP" "$EXTLINUX"
rm -f "$TMP"

echo ""
echo "=== Updated extlinux.conf (tail) ==="
sudo cat "$EXTLINUX" | tail -10

echo ""
echo "=== Ready to reboot ==="
echo "Run: sudo reboot"
echo ""
echo "If the new overlay causes boot trouble: interrupt the 30s boot timeout"
echo "and select 'primary kernel' as fallback. To revert this script's changes:"
echo "  ./scripts/enable_max96712_overlay.sh --revert"
