#!/bin/bash
# lijag_stream_diag.sh — capture pre/post diagnostics around a v4l2-ctl
# stream attempt on a D457 behind MAX96712 on LI-JAG-ADP-GMSL2-8CH.
#
# Goal: determine whether the streaming hang is upstream of NVCSI
# (no frames reach the deserializer's MIPI TX) vs. downstream (NVCSI/VI
# never sees the frames the chip is sending).
#
# Usage on Orin:
#     sudo ./scripts/lijag_stream_diag.sh [/dev/videoX]
#
# Default video node: /dev/video0 (depth on link A).
#
# Outputs:
#   - stdout (also tee'd by caller if desired)
#   - /tmp/lijag_stream_diag.out (canonical copy)

set -u
VIDEO=${1:-/dev/video0}
I2C_BUS=2
DSER_ADDR=0x29
SER_ADDR=0x40
OUT=/tmp/lijag_stream_diag.out

# Funnel everything to both stdout and the canonical out file.
exec > >(tee "$OUT") 2>&1

read_dser() {
    local r=$1
    local hi=$(( (r >> 8) & 0xff ))
    local lo=$(( r & 0xff ))
    i2ctransfer -y -f $I2C_BUS w2@$DSER_ADDR $hi $lo r1 2>/dev/null \
        || echo "ERR"
}

read_ser() {
    local r=$1
    local hi=$(( (r >> 8) & 0xff ))
    local lo=$(( r & 0xff ))
    i2ctransfer -y -f $I2C_BUS w2@$SER_ADDR $hi $lo r1 2>/dev/null \
        || echo "ERR"
}

dump_dser_status() {
    echo "  0x000D DEV_ID            = $(read_dser 0x000D)"
    echo "  0x0006 LINK_EN           = $(read_dser 0x0006)"
    echo "  0x0010 LINK_LOCK_A       = $(read_dser 0x0010)"
    echo "  0x002A LinkA video lock  = $(read_dser 0x002A)"
    echo "  0x002B LinkB video lock  = $(read_dser 0x002B)"
    echo "  0x002C LinkC video lock  = $(read_dser 0x002C)"
    echo "  0x002D LinkD video lock  = $(read_dser 0x002D)"
    echo "  0x040B MIPI ctrl0        = $(read_dser 0x040B)"
    echo "  0x041A MIPI ctrl1        = $(read_dser 0x041A)"
    echo "  0x08A0 MIPI TX10/PHY cfg = $(read_dser 0x08A0)"
    echo "  0x08A2 MIPI TX12         = $(read_dser 0x08A2)"
    echo "  0x08A3 MIPI lane map A   = $(read_dser 0x08A3)"
    echo "  0x08A4 MIPI lane map B   = $(read_dser 0x08A4)"
    echo "  0x090B Pipe X enable     = $(read_dser 0x090B)"
    echo "  0x094B Pipe Y enable     = $(read_dser 0x094B)"
    echo "  0x098B Pipe Z enable     = $(read_dser 0x098B)"
    echo "  0x09CB Pipe U enable     = $(read_dser 0x09CB)"
    echo "  0x092D Pipe X DPHY map   = $(read_dser 0x092D)"
    echo "  0x096D Pipe Y DPHY map   = $(read_dser 0x096D)"
    echo "  0x09AD Pipe Z DPHY map   = $(read_dser 0x09AD)"
    echo "  0x09ED Pipe U DPHY map   = $(read_dser 0x09ED)"
    echo "  0x1D00 PHY 1 status      = $(read_dser 0x1D00)"
    echo "  0x1E00 PHY 2 status      = $(read_dser 0x1E00)"
    echo "  0x00F0 Map ID 0/1        = $(read_dser 0x00F0)"
    echo "  0x00F1 Map ID 2/3        = $(read_dser 0x00F1)"
    echo "  0x00F4 Pipe enable mask  = $(read_dser 0x00F4)"
}

dump_ser_status() {
    echo "  0x0000 ID/RESET          = $(read_ser 0x0000)"
    echo "  0x000D DEV_ID            = $(read_ser 0x000D)"
    echo "  0x0102 video lock        = $(read_ser 0x0102)"
    echo "  0x0383 PCLKDET           = $(read_ser 0x0383)"
    echo "  0x0100 video TX0 ena     = $(read_ser 0x0100)"
    echo "  0x0311 PHY status        = $(read_ser 0x0311)"
}

dump_rtcpu() {
    echo "--- stats:"
    cat /sys/kernel/debug/tegra_rtcpu_trace/stats 2>/dev/null \
        || echo "(no rtcpu_trace/stats)"
    echo "--- last_event:"
    cat /sys/kernel/debug/tegra_rtcpu_trace/last_event 2>/dev/null \
        || echo "(none)"
    echo "--- last_exception:"
    cat /sys/kernel/debug/tegra_rtcpu_trace/last_exception 2>/dev/null \
        || echo "(none)"
}

echo "============================================================"
echo "lijag_stream_diag.sh"
echo "Date:    $(date -Is)"
echo "Kernel:  $(uname -r)"
echo "Video:   $VIDEO"
echo "============================================================"
echo ""

echo "=== [1/8] PRE-STREAM: V4L2 format on $VIDEO ==="
v4l2-ctl -d $VIDEO -V 2>&1
echo ""

echo "=== [2/8] PRE-STREAM: MAX96712 deserializer status ==="
dump_dser_status
echo ""

echo "=== [3/8] PRE-STREAM: MAX9295 serializer (camera-side) status ==="
dump_ser_status
echo ""

echo "=== [4/8] PRE-STREAM: rtcpu_trace ==="
dump_rtcpu
echo ""

echo "=== [5/9] Clear dmesg + arm RTCPU tracing ==="
dmesg -c > /dev/null
echo "(dmesg cleared)"
# tegra_rtcpu trace events expose what the camera RTCPU (RCE) firmware sees
# on the NVCSI brick: rtcpu_nvcsi_intr (PHY/STREAM error class), rtcpu_vinotify_event
# (frame-start / frame-end), rtcpu_vinotify_error (overflow / crc / SOT errors),
# camrtc_log_str (debug strings). Zero events with an active stream attempt =
# NVCSI brick saw no PHY transitions = data isn't reaching the receiver at all.
TRACE_DIR=/sys/kernel/debug/tracing
if [[ -d "$TRACE_DIR/events/tegra_rtcpu" ]]; then
    echo 0 > "$TRACE_DIR/tracing_on" 2>/dev/null
    echo > "$TRACE_DIR/trace" 2>/dev/null
    echo 1 > "$TRACE_DIR/events/tegra_rtcpu/enable" 2>/dev/null
    echo 1 > "$TRACE_DIR/tracing_on" 2>/dev/null
    echo "(tegra_rtcpu trace events armed)"
else
    echo "(WARN: $TRACE_DIR/events/tegra_rtcpu not found — kernel may lack CONFIG_TEGRA_CAMERA_RTCPU)"
fi
echo ""

echo "=== [6/9] STREAM ATTEMPT (8s wall, 2 frames) on $VIDEO ==="
echo "Command: timeout 8 v4l2-ctl -d $VIDEO --stream-mmap=4 --stream-count=2 --stream-to=/tmp/lijag_stream.bin"
echo ""
timeout 8 v4l2-ctl -d $VIDEO --stream-mmap=4 --stream-count=2 \
    --stream-to=/tmp/lijag_stream.bin 2>&1
RC=$?
echo "v4l2-ctl exit code: $RC  (124 = timeout/hang, 0 = got frames)"
ls -la /tmp/lijag_stream.bin 2>/dev/null \
    || echo "(no output file)"
echo ""

# Stop tracing immediately so the post-stream snapshot doesn't stir new events.
if [[ -d "$TRACE_DIR/events/tegra_rtcpu" ]]; then
    echo 0 > "$TRACE_DIR/tracing_on" 2>/dev/null
fi

echo "=== [7/9] POST-STREAM: MAX96712 deserializer status ==="
dump_dser_status
echo ""
echo "=== POST-STREAM: MAX9295 serializer status ==="
dump_ser_status
echo ""

echo "=== [8/9] POST-STREAM: rtcpu_trace summary ==="
dump_rtcpu
echo ""

echo "=== [9/9] tegra_rtcpu tracefs events captured during stream ==="
if [[ -d "$TRACE_DIR/events/tegra_rtcpu" ]]; then
    # Filter to camera/CSI/VI events; skip empty boilerplate.
    grep -E "rtcpu_nvcsi_intr|rtcpu_vinotify|camrtc_log|rtcpu_start|rtcpu_string" \
        "$TRACE_DIR/trace" 2>/dev/null \
        | head -200
    EVCNT=$(grep -c -E "rtcpu_(nvcsi|vinotify|start|string)|camrtc_log" \
            "$TRACE_DIR/trace" 2>/dev/null || echo 0)
    echo ""
    echo "(camera-related trace events captured: $EVCNT)"
    echo "  zero rtcpu_vinotify_event = no SoF seen by VI demux"
    echo "  rtcpu_nvcsi_intr with class=PHY_INTR  = clock/lane error"
    echo "  rtcpu_nvcsi_intr with class=STREAM_*  = packet-level error"
    # Disarm
    echo 0 > "$TRACE_DIR/events/tegra_rtcpu/enable" 2>/dev/null
else
    echo "(tracing not available)"
fi
echo ""

echo "--- dmesg captured during stream attempt ---"
dmesg
echo ""
echo "============================================================"
echo "Output saved to: $OUT"
echo "============================================================"
