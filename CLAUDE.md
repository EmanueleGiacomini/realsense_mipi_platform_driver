# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Session start — read these before doing anything

This project has a knowledge vault that is **the source of truth** for procedures, hardware facts, and decisions. Memory contains only stable facts (user profile, project goal); everything else lives in the vault. When you start a session on this repo, read these in order:

1. **`~/Work/Obsidian/Pegasus-realsense/Procedures/workflow-safety-rules.md`** — required reading. The 8 rules exist because we bricked the Orin once. Don't repeat the mistake.
2. **`~/Work/Obsidian/Pegasus-realsense/00-Index.md`** — vault landing page; orient by the active runbooks listed there.
3. **`~/Work/Obsidian/Pegasus-realsense/Hardware/LI-JAG-ADP-GMSL2-8CH.md`** — the hardware we're targeting, especially the I2C bus map and CSI brick assignment.
4. **`~/Work/Obsidian/Pegasus-realsense/Procedures/deploy-driver.md`** — pre-flight + safe install procedure. Don't deploy without reading this.
5. **`~/Work/Obsidian/Pegasus-realsense/Procedures/long-running-via-tmux.md`** — required working rule. Any command taking more than ~30 s (build, source clone, on-device test loop) **must** run inside the named `d4xx-build` tmux session with tee'd log + `<<DONE rc=N>>` sentinel. Reserve foreground `Bash` calls for fast, reversible operations.

For symptom-driven work:
- streaming bringup → `Procedures/test-streaming.md`
- broken boot / Orin unreachable → `Procedures/recover-bricked-orin.md`
- post-merge / branch state questions → `References/github-issues.md`

When you discover a bench-verified fact (something you proved on hardware, not hypothesized), append it to `Findings/` in the vault — but only if it's verified.

## Project Overview

Linux kernel driver and userspace utilities for Intel RealSense D4XX series 3D depth cameras operating over GMSL (Gigabit Multimedia Serial Link) MIPI CSI-2 interface on NVIDIA Jetson platforms. Licensed under GPL-2.0.

**Supported platforms:** Jetson AGX Xavier (JetPack 4.6.1, 5.0.2, 5.1.2) and AGX Orin (JetPack 6.0, 6.1, 6.2, 6.2.1).
**Supported cameras:** D457 (primary), D401, D40x, D41x, D43x, D45x, D46x.
**Active target hardware:** AGX Orin Devkit + LeopardImaging LI-JAG-ADP-GMSL2-8CH carrier (P3762_A03), 2× MAX96712, up to 6× D457.

## Build Commands

Build dependencies (Ubuntu syntax — adapt for Arch/Omarchy with `pacman`):
```bash
sudo apt install -y build-essential bc wget flex bison curl libssl-dev xxd
```

Full build flow for a given JetPack version (e.g., 6.2):
```bash
./setup_workspace.sh 6.2          # Clone NVIDIA sources, install toolchain
./apply_patches.sh 6.2            # Apply D4XX patches (default action is apply; no "apply" keyword)
./build_all.sh 6.2                # Build kernel, DTBs, and driver modules
```

Build outputs go to `images/<version>/` (e.g., `images/6.x/`).

CI runs these three steps for each JetPack version (see `.github/workflows/build-jp*.yml`). CI requires `git config user.email/name` to be set before `apply_patches.sh`.

### Patch application — usage

```bash
./apply_patches.sh [--one-cam | --dual-cam] <version>   # Apply (default action). Just <version>, no "apply" keyword.
./apply_patches.sh reset <version>                       # Reset all patches to upstream HEAD.
```

The `--one-cam`/`--dual-cam` options apply to JetPack 5.0.2 only. **Note:** writing `apply_patches.sh apply 6.2` does not work — the script treats `apply` as an unrecognized version. Use `apply_patches.sh 6.2` for the apply action.

### Deploy — DO NOT use the legacy deploy_kernel scripts on a native build

`scripts/deploy_kernel.sh` and `scripts/deploy_kernel_6.2.sh` were written for **remote deploy from a build PC to a separate Jetson over SSH**. They package a `rootfs.tar.gz` that is meant to be flashed via SDK Manager onto a clean device — not extracted onto a running system. **Extracting that tarball onto a running Jetson via `tar -xzvf … -C /` will overwrite system files (`/etc/sudoers`, `/lib/modules/<ver>/`, `/boot/Image`) and may brick the device.** It bit us once.

For native-build-on-Jetson workflow, install only the specific built `.ko` and `.dtbo` files manually. The full safe procedure lives in `~/Work/Obsidian/Pegasus-realsense/Procedures/deploy-driver.md`.

## Testing

Tests run on-device using pytest (Python 3). Located in `test/`.

```bash
cd test
python3 run_ci.py                          # Run all D457 tests
python3 run_ci.py -r test_fw_version       # Run specific test by regex
pytest -vs -m d457 test/                   # Direct pytest invocation
```

Pytest marker: `d457` (defined in `test/pytest.ini`). Test timeout: 200 seconds.

Streaming smoke test recipe (with rtcpu trace events) lives in the vault: `Procedures/test-streaming.md`.

## Architecture

### Driver stack (top to bottom)

```
V4L2 userspace (v4l2-ctl, gstreamer, etc.)
    ↓
Kernel V4L2 / media framework
    ↓
D4XX kernel driver (kernel/realsense/d4xx.c, ~6500 lines)
    ↓ I2C
SerDes (MAX9295 serializer / MAX9296 or MAX96712 deserializer)
    ↓ GMSL link
RealSense D4XX camera module
```

### Key directories

- **`kernel/realsense/d4xx.c`** — The main driver. Single-file V4L2 subdevice driver handling I2C communication, MIPI CSI-2 stream config, firmware control (DFU), calibration data, metadata capture, and V4L2 controls (exposure, laser power, AE ROI, etc.). Registers four sensor subdevices per camera: Depth, RGB, IR (Y8/Y8I/Y12I), and IMU.
- **`kernel/kernel-4.9/`, `kernel/kernel-5.10/`, `kernel/kernel-jammy-src/`** — Kernel patches organized by JetPack generation: 4.6.1 uses kernel 4.9, 5.x uses kernel 5.10, 6.x uses kernel-jammy-src.
- **`kernel/nvidia/`** — NVIDIA driver patches (max9295/max9296 SerDes, VI capture engine) organized by JetPack version.
- **`nvidia-oot/`** — Out-of-tree NVIDIA module patches for JetPack 6.x (subdirs `6.0/`, `6.1/`, `6.2/`, `6.2.1/`). Has its own Makefile for building conftest, hwpm, nvidia-oot, nvgpu, nvidia-display modules. **MAX96712 driver lives here** (`nvidia-oot/<ver>/0006-Adding-max96712-support-for-D4xx.patch`).
- **`hardware/realsense/`** — Device tree source files. Xavier uses `.dtsi` includes (`tegra194-camera-d4xx-*.dtsi`), Orin uses DT overlays (`tegra234-camera-d4xx-overlay*.dts`). Single-camera and dual-camera variants exist, plus `.calib.` variants for calibration. EVB and FG12-16ch board variants are upstream; the LI-JAG board overlay is project-specific.
- **`hardware/nvidia/`** — Platform-level DT patches (`t19x/galen/` for Xavier, `t23x/` for Orin T234).
- **`scripts/`** — Build orchestration. `setup-common` defines version-to-revision mappings and kernel directory selection. `source_sync_*.sh` scripts clone NVIDIA kernel repos. `SerDes_D457_*.sh` scripts configure serializer/deserializer registers.
- **`utilities/streamApp/`** — C++ streaming application with V4L2 interface (`v4l2_ds5_mipi.cpp`), camera capabilities enumeration, GUI, and firmware logging.
- **`utilities/JsonToBin/`** — Python tool to convert JSON camera presets to binary register configs.

### Video device layout (per camera)

Each camera creates 6 V4L2 video devices:
- video0: Depth (Z16)
- video1: Depth metadata (D4XX custom format)
- video2: Color RGB (RGB888/YUV422)
- video3: Color RGB metadata
- video4: IR (GREY, Y8I, Y12I)
- video5: IMU

### Cross-compilation

The build system cross-compiles for ARM64. Toolchains vary by JetPack:
- JP 4.6.1: Linaro GCC 7.3
- JP 5.x: Bootlin GCC 9.3
- JP 6.x: Bootlin GCC 11.3 (`aarch64-buildroot-linux-gnu`)

`setup_workspace.sh` automatically downloads the appropriate toolchain.

In our setup we **cross-compile on the dev PC** (x86_64) using the upstream `setup_workspace.sh` / `apply_patches.sh` / `build_all.sh` flow — the same flow CI runs. Built artifacts land in `images/<ver>/rootfs/` and are rsync'd / scp'd to the Orin and installed per-file. The Jetson is a deploy + test target, not a build host. See vault `Procedures/deploy-driver.md` for the workflow.

### Version mapping (in `scripts/setup-common`)

| JetPack | L4T Revision | Kernel Dir |
|---------|-------------|------------|
| 4.6.1   | 32.7.1      | kernel/kernel-4.9 |
| 5.0.2   | 35.1        | kernel/kernel-5.10 |
| 5.1.2   | 35.4.1      | kernel/kernel-5.10 |
| 6.0     | 36.3        | kernel/kernel-jammy-src |
| 6.1     | 36.4        | kernel/kernel-jammy-src |
| 6.2     | 36.4.3      | kernel/kernel-jammy-src |
| 6.2.1   | 36.4.4      | kernel/kernel-jammy-src |

## Branching

- `master` — primary/release branch (upstream IntelRealSense).
- `dev` — active development branch upstream; integration target for all merged PRs.
- `lijag-fresh` — our active development branch; tracks `intelrs/dev`. Created 2026-05-04 after a clean restart from upstream `dev`.
- `lijag-base` — *archaeology*; the prior LI-JAG iteration with patches 0010/0011/0012 and the lijag DT overlay. Preserved for reference; do not commit new work here.

CI builds run on pushes to `master` and `dev`, and on all PRs.

## Concurrency notes

- In SERDES builds, hold `serdes_lock__` while scanning or assigning global topology slots (`ds5_inited[]`, `dser_inited[]`).
- Protect per-camera mutable slot state (`ds5_primary`, `depth/rgb/ir/imu_streaming`) with `struct ds5_dev::lock`.
- Protect per-deserializer slot assignment (`dser_dev`) with `struct dser_control::lock`.
- Any path that releases a primary camera slot must clear both camera-slot ownership and deserializer-slot ownership together; do not clear only `ds5_primary`. Use a shared helper so teardown/error paths stay symmetric. The `ds5_release_slot()` helper always acquires and releases `serdes_lock__` internally; callers must not hold the lock when calling it.
- For sibling-health checks, snapshot pointers/flags under lock and perform I2C probing after unlocking.
- Do not use `0x5020` as non-DFU reset-ready status; in non-DFU mode it is not a readiness source of truth. For HW reset readiness, scratch `DS5_*_CONTROL_STATUS` with a non-zero sentinel before reset and wait for FW to restore default `0x0000` after reset. Use `0x5020` only for DFU magic detection.
- After reset completion, use `DS5_DEVICE_TYPE` validity as the operational-readiness gate for code that depends on firmware-populated stream/config state. `DS5_FW_VERSION` can come back earlier and should only be treated as basic liveness, not full post-reset readiness.
- On each HW reset, clear cached values for firmware-populated readiness registers before polling readiness (for example clear `cached_device_type` before waiting for `DS5_DEVICE_TYPE`). Do not let pre-reset cache values short-circuit post-reset readiness checks.
- For polling loops expecting transient I2C failures (HWMC status checks, reset readiness polls, DFU timeout checks), use `ds5_read_poll()` which performs a single-shot regmap read without retry or logging. This prevents false warnings and excessive log spam. Reserve `ds5_read()` for normal I2C operations where retry semantics are desired.
- In `ds5_mux_s_stream()`, treat pre-toggle "already streaming" as no-op only when state is coherent; after reset-generation invalidation on start path, force stop + state clear and proceed with normal reconfiguration flow.

## Post-patch instruction hygiene

After every confirmed code patch, review both `.github/copilot-instructions.md` and `CLAUDE.md` against the final net diff, including any follow-up tuning edits.

- Check for stale architectural claims and remove or correct them immediately.
- Check whether the patch exposed a reusable convention; if it did, write it down as a general rule instead of leaving it implicit in code.
- If the patch changed the locking, usage, or API contract of a helper or utility function (e.g. moved lock acquisition inside/outside, changed required caller context, or altered error handling), immediately update all documentation and instructions to reflect the new contract. Always check for this class of change after any helper edit.
- If no new convention was exposed, state that explicitly in the final report and include a short justification.
- Do not treat the task as complete until that review outcome has been reported.

When the convention belongs in a runbook (e.g., a new install step, a new test recipe), put it in the vault under `Procedures/` rather than in CLAUDE.md. Keep CLAUDE.md focused on repo-internal architecture; keep the vault focused on workflow + hardware reality.
