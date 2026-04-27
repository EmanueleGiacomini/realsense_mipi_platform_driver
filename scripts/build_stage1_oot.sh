#!/bin/bash
# build_stage1_oot.sh — minimal OOT build for MAX96712 work on Jetson Orin.
#
# Builds ONLY our patched max9296.ko (against the RUNNING kernel) and compiles
# the MAX96712 device tree overlay. Assumes:
#   - ./apply_patches.sh 6.2 has already set up sources_6.2/
#   - running kernel has /lib/modules/$(uname -r)/build/ with headers
#   - conftest.h is available (we use a minimal stub since colleague's proves
#     only a few symbols matter for our build)
#
# Run FROM the repo root on the Jetson. Output goes to images/stage1/.

set -e

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

JP=6.2
SRCS="$REPO_ROOT/sources_$JP"
KVER=$(uname -r)
KHDRS=/lib/modules/$KVER/build
OUT="$REPO_ROOT/images/stage1"

if [[ ! -d "$SRCS/nvidia-oot" ]]; then
    echo "ERROR: $SRCS/nvidia-oot not found. Run ./apply_patches.sh 6.2 first." >&2
    exit 1
fi
if [[ ! -d "$KHDRS" ]]; then
    echo "ERROR: kernel headers not found at $KHDRS" >&2
    echo "       Install with: sudo apt install nvidia-l4t-kernel-oot-headers" >&2
    exit 1
fi

mkdir -p "$OUT"

# ---- 1. Set up a minimal conftest.h ----
# Required by nvidia-oot's build system. Our max9296.c uses only:
#   NV_I2C_DRIVER_STRUCT_PROBE_WITHOUT_I2C_DEVICE_ID_ARG (Linux 6.3+, NOT defined here)
#   NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT         (Linux 5.x has int return, DEFINED here)
CONFTEST_DIR="$OUT/nvidia-conftest"
mkdir -p "$CONFTEST_DIR/nvidia"
cat > "$CONFTEST_DIR/nvidia/conftest.h" <<'EOF'
/* Minimal conftest.h for 5.15 Tegra kernel — matches kernel 5.15's i2c_driver
 * signatures: probe takes (client, id), remove returns int. */
#ifndef _NV_CONFTEST_H
#define _NV_CONFTEST_H

#define NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT 1
/* NV_I2C_DRIVER_STRUCT_PROBE_WITHOUT_I2C_DEVICE_ID_ARG intentionally NOT defined */

#endif
EOF

# ---- 2. Build max9296.ko via a standalone Kbuild ----
BUILDDIR="$OUT/build"
mkdir -p "$BUILDDIR"

# Copy the patched max9296.c and a minimal Kbuild
cp "$SRCS/nvidia-oot/drivers/media/i2c/max9296.c" "$BUILDDIR/"

cat > "$BUILDDIR/Kbuild" <<EOF
ccflags-y += -I$SRCS/nvidia-oot/include
ccflags-y += -I$CONFTEST_DIR
obj-m := max9296.o
EOF

cat > "$BUILDDIR/Makefile" <<'EOF'
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

echo "=== Building max9296.ko against $KHDRS ==="
make -C "$KHDRS" M="$BUILDDIR" modules

if [[ ! -f "$BUILDDIR/max9296.ko" ]]; then
    echo "ERROR: build produced no max9296.ko" >&2
    exit 1
fi

echo ""
echo "=== Built max9296.ko info ==="
modinfo "$BUILDDIR/max9296.ko" | head -10
echo ""
echo "=== Confirming MAX96712 symbols are present ==="
nm --defined-only "$BUILDDIR/max9296.ko" | grep -E 'max96712|is_max96712' | head -5 || {
    echo "WARNING: no MAX96712 symbols in built module — patches may not have applied"
    exit 1
}

# ---- 3. Compile the DT overlay ----
# Source from our fork directly (not sources_6.2 copy) so edits to the .dts
# in hardware/realsense/ flow through via rsync without re-running
# apply_patches.sh.
OVERLAY_SRC="$REPO_ROOT/hardware/realsense/tegra234-camera-d4xx-overlay-max96712-lijag.dts"
OVERLAY_DTBO="$OUT/tegra234-camera-d4xx-overlay-max96712-lijag.dtbo"

if [[ ! -f "$OVERLAY_SRC" ]]; then
    echo "ERROR: DT overlay source missing at $OVERLAY_SRC" >&2
    exit 1
fi

echo ""
echo "=== Compiling DT overlay ==="
# preprocess + compile. The overlay uses dt-bindings headers from two trees:
#   - kernel DT bindings (e.g., dt-bindings/clock/tegra234-clock.h)
#   - NVIDIA platform DT bindings (e.g., dt-bindings/tegra234-p3737-0000+p3701-0000.h)
cpp -nostdinc -undef -x assembler-with-cpp \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include" \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include/platforms" \
    -I"$SRCS/hardware/nvidia/t23x/nv-public/include/kernel" \
    -I"$SRCS/kernel/kernel-jammy-src/include" \
    -I"$SRCS/kernel/kernel-jammy-src/scripts/dtc/include-prefixes" \
    "$OVERLAY_SRC" -o "$OUT/overlay.dts.pp"
dtc -@ -I dts -O dtb -o "$OVERLAY_DTBO" "$OUT/overlay.dts.pp"
echo "Overlay: $OVERLAY_DTBO ($(stat -c%s "$OVERLAY_DTBO") bytes)"

# ---- 4. Summary ----
echo ""
echo "=== Stage 1 build complete ==="
echo "Artifacts in $OUT:"
ls -la "$BUILDDIR/max9296.ko" "$OVERLAY_DTBO"
echo ""
echo "Next: run scripts/install_stage1.sh to deploy and reload"
