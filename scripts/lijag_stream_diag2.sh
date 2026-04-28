#!/bin/bash
# lijag_stream_diag2.sh — captures MAX96712 + MAX9295 register state DURING
# an active v4l2 stream attempt, plus NVCSI debugfs while capture is engaged.
#
# Strategy: spawn v4l2-ctl in the background (10s timeout), wait 1s for
# stream-start to settle, then sample key registers + sysfs every 250ms for
# ~6s. Stop, kill v4l2-ctl, then dump dmesg.
#
# Usage on Orin:
#   sudo ./scripts/lijag_stream_diag2.sh [/dev/videoX]

set -u
VIDEO=${1:-/dev/video0}
I2C_BUS=2
DSER=0x29
SER=0x40
OUT=/tmp/lijag_stream_diag2.out

exec > >(tee "$OUT") 2>&1

read_dser() {
    local r=$1
    local hi=$(( (r >> 8) & 0xff )); local lo=$(( r & 0xff ))
    i2ctransfer -y -f $I2C_BUS w2@$DSER $hi $lo r1 2>/dev/null || echo ERR
}
read_ser() {
    local r=$1
    local hi=$(( (r >> 8) & 0xff )); local lo=$(( r & 0xff ))
    i2ctransfer -y -f $I2C_BUS w2@$SER $hi $lo r1 2>/dev/null || echo ERR
}

snap_key_regs() {
    local tag=$1
    echo "[$tag t=$(date +%s.%3N)]"
    echo "  DSER 0x040B BACKTOP12         = $(read_dser 0x040B)"
    echo "  DSER 0x00F4 PIPE_EN           = $(read_dser 0x00F4)"
    echo "  DSER 0x00F0 MAP_ID 0/1        = $(read_dser 0x00F0)"
    echo "  DSER 0x00F1 MAP_ID 2/3        = $(read_dser 0x00F1)"
    echo "  DSER 0x002A LinkA video lock  = $(read_dser 0x002A)"
    echo "  DSER 0x08A0 MIPI_PHY0         = $(read_dser 0x08A0)"
    echo "  DSER 0x08A2 MIPI_PHY2         = $(read_dser 0x08A2)"
    echo "  DSER 0x094A pipeX TX10        = $(read_dser 0x094A)"
    echo "  DSER 0x090B pipeX TX11        = $(read_dser 0x090B)"
    echo "  DSER 0x092D pipeX DPHY_DEST   = $(read_dser 0x092D)"
    echo "  DSER 0x0973 MIPI_TX51         = $(read_dser 0x0973)"
    echo "  DSER 0x0418 BACKTOP25         = $(read_dser 0x0418)"
    echo "  DSER 0x1D00 PHY1 status       = $(read_dser 0x1D00)"
    echo "  DSER 0x1E00 PHY2 status       = $(read_dser 0x1E00)"
    echo "  SER  0x0102 video lock        = $(read_ser 0x0102)"
    echo "  SER  0x0383 PCLKDET           = $(read_ser 0x0383)"
    echo "  SER  0x0100 video TX0         = $(read_ser 0x0100)"
    echo "  SER  0x0311 PHY status        = $(read_ser 0x0311)"
}

echo "============================================================"
echo "lijag_stream_diag2.sh — mid-stream sampler"
echo "Date:    $(date -Is)"
echo "Kernel:  $(uname -r)"
echo "Video:   $VIDEO"
echo "============================================================"
echo ""

dmesg -c > /dev/null
echo "(dmesg cleared)"
echo ""

snap_key_regs PRE
echo ""

echo "=== Spawning v4l2-ctl in background (10s timeout) ==="
( timeout 10 v4l2-ctl -d $VIDEO --stream-mmap=4 --stream-count=10 \
    --stream-to=/tmp/lijag_stream2.bin > /tmp/lijag_v4l2_stdout.log 2>&1 ) &
V4L2_PID=$!
echo "v4l2-ctl pid=$V4L2_PID"
sleep 1.0

echo ""
echo "=== Sampling registers every 250ms during stream ==="
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    snap_key_regs MID-$i
    sleep 0.25
done

echo ""
echo "=== Wait for v4l2-ctl exit ==="
wait $V4L2_PID 2>/dev/null
RC=$?
echo "v4l2-ctl exit code: $RC"
ls -la /tmp/lijag_stream2.bin 2>/dev/null
cat /tmp/lijag_v4l2_stdout.log 2>/dev/null | head -20

echo ""
snap_key_regs POST
echo ""

echo "=== rtcpu_trace ==="
echo "--- stats:"
cat /sys/kernel/debug/tegra_rtcpu_trace/stats
echo "--- last_event:"
cat /sys/kernel/debug/tegra_rtcpu_trace/last_event
echo "--- last_exception:"
cat /sys/kernel/debug/tegra_rtcpu_trace/last_exception

echo ""
echo "=== nvcsi debugfs ==="
ls -la /sys/kernel/debug/nvcsi/ 2>&1
find /sys/kernel/debug/nvcsi -maxdepth 3 -type f 2>/dev/null | while read f; do
    sz=$(stat -c%s "$f" 2>/dev/null)
    if [[ -n "$sz" && "$sz" -lt 1024 ]]; then
        echo "--- $f (size=$sz):"
        cat "$f" 2>/dev/null | head -5
    fi
done

echo ""
echo "=== dmesg from stream attempt ==="
dmesg

echo ""
echo "============================================================"
echo "Output saved to: $OUT"
echo "============================================================"
