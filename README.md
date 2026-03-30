# Xenomai 4 (EVL) on Milk-V Jupiter / SpacemiT K1 (RISC-V)

> **Status:** Work-in-progress — no official upstream support exists yet.  
> **Target board:** Milk-V Jupiter (SpacemiT K1, RISC-V RV64GCV)  
> **Kernel base:** `linux-6.6` — SpacemiT fork [`v6.6.63`](https://gitee.com/spacemit-buildroot/linux-6.6-v2.1.y/tree/v6.6.63/)  
> **Real-time layer:** Xenomai 4 / EVL (Eclipse Versatile Linux)

---

## Table of Contents

1. [Project Purpose](#1-project-purpose)
2. [Repository Layout](#2-repository-layout)
3. [Background & Research Findings](#3-background--research-findings)
   - 3.1 [SpacemiT K1 SoC](#31-spacemit-k1-soc)
   - 3.2 [Xenomai 4 / EVL Architecture](#32-xenomai-4--evl-architecture)
   - 3.3 [RISC-V EVL Support Status](#33-risc-v-evl-support-status)
   - 3.4 [Key Porting Challenges](#34-key-porting-challenges)
   - 3.5 [Patch Strategy](#35-patch-strategy)
4. [Prerequisites](#4-prerequisites)
5. [Quick-Start Build Guide](#5-quick-start-build-guide)
6. [Flashing to SD Card](#6-flashing-to-sd-card)
7. [Testing EVL on the Board](#7-testing-evl-on-the-board)
8. [s-aiotm Integration Targets](#8-s-aiotm-integration-targets)
9. [Known Issues & Workarounds](#9-known-issues--workarounds)
10. [References](#10-references)

---

## 1. Project Purpose

This repository contains **only our own scripts, patches, configs, and documentation** for porting Xenomai 4 (EVL) to the Milk-V Jupiter development board.

The goal is to enable the following **s-aiotm** atomic capabilities on a RISC-V edge node:

| ID | Capability | EVL Relevance |
|----|-----------|---------------|
| 01 | Heterogeneous protocol adaptation | Hard-RT driver threads for fieldbus (CAN, EtherCAT, RS-485) |
| 03 | Real-time data bus | Deterministic publish/subscribe with bounded latency |
| 04 | Closed-loop control execution | Sub-millisecond control loops via EVL threads |
| 08 | Task scheduling | Priority-based preemptive scheduling with EVL scheduler |

---

## 2. Repository Layout

```
spacemit-xenomai/
├── README.md                   ← This file
├── .gitignore                  ← Excludes all non-owned artefacts
│
├── docs/
│   ├── architecture.md         ← EVL dual-kernel architecture notes
│   ├── porting-notes.md        ← RISC-V specific porting details
│   └── testing.md              ← Latency test procedures & results
│
├── configs/
│   └── k1_evl_defconfig        ← Kernel config fragment for EVL on K1
│
├── patches/
│   ├── 0001-evl-riscv-dovetail-base.patch   ← Dovetail interrupt pipeline
│   ├── 0002-evl-riscv-fpu-context.patch     ← FPU context switching
│   └── 0003-evl-k1-clocksource.patch        ← K1 timer/clocksource fixes
│
└── scripts/
    ├── build/
    │   ├── 00-setup-env.sh     ← Clone kernel + EVL, set toolchain
    │   ├── 01-apply-patches.sh ← Apply EVL Dovetail patches
    │   ├── 02-configure.sh     ← Merge defconfig + EVL fragment
    │   └── 03-build-kernel.sh  ← Cross-compile kernel + modules
    ├── patch/
    │   └── gen-patch.sh        ← Helper to generate patches from git
    └── flash/
        └── flash-sdcard.sh     ← Write image to SD card (Linux host)
```

> **Rule:** Only files under `docs/`, `configs/`, `patches/`, and `scripts/` are tracked in git.  
> Kernel sources, toolchains, build outputs, and images are **never** committed.

---

## 3. Background & Research Findings

### 3.1 SpacemiT K1 SoC

| Property | Value |
|----------|-------|
| ISA | RISC-V RV64GCVB (with Vector 1.0 + BitManip) |
| Cores | 8× X60 (SpacemiT custom, in-order + OoO hybrid) |
| Timer | RISC-V standard `mtime`/`mtimecmp` per hart + CLINT |
| Interrupt controller | PLIC (Platform-Level Interrupt Controller) |
| Linux defconfig | `spacemit_k1_v2_defconfig` |
| Kernel repo | `linux-6.6` SpacemiT fork v6.6.63 |

The K1 uses the standard RISC-V timer infrastructure (`riscv_timer` driver, `CLINT`), which is important because EVL's Dovetail pipeline hooks into the timer interrupt path.

### 3.2 Xenomai 4 / EVL Architecture

Xenomai 4 (branded **EVL — Eclipse Versatile Linux**) is a complete rewrite of Xenomai 3. It uses the **Dovetail** interrupt pipeline (replacing the older I-pipe) to create a dual-kernel architecture:

```
┌─────────────────────────────────────────────────────┐
│                  User Space                          │
│   EVL threads (libevl)    │   Normal POSIX threads   │
└───────────────┬───────────┴──────────────────────────┘
                │ EVL syscalls          │ Linux syscalls
┌───────────────▼───────────────────────▼──────────────┐
│                    Linux Kernel                       │
│  ┌─────────────────────┐   ┌────────────────────┐    │
│  │   EVL Core (in-tree)│   │  Linux Scheduler   │    │
│  │  - EVL scheduler    │   │  (SCHED_NORMAL etc) │   │
│  │  - EVL clock        │   └────────────────────┘    │
│  │  - EVL threads      │                             │
│  └──────────┬──────────┘                             │
│             │                                        │
│  ┌──────────▼──────────────────────────────────────┐ │
│  │         Dovetail Interrupt Pipeline              │ │
│  │  Stage 0 (OOB) → EVL handles first              │ │
│  │  Stage 1 (in-band) → Linux handles normally     │ │
│  └──────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

Key differences from Xenomai 3 / PREEMPT_RT:

| Feature | Xenomai 3 (I-pipe) | Xenomai 4 (Dovetail) | PREEMPT_RT |
|---------|-------------------|---------------------|------------|
| Kernel modification | Heavy (I-pipe) | Lighter (Dovetail) | Moderate |
| RISC-V support | None | Partial (WIP) | Upstream |
| Latency (typical) | ~5–20 µs | ~5–15 µs | ~20–100 µs |
| Upstream path | No | Planned | Merged |
| User API | Xenomai POSIX skin | libevl (native) | Standard pthreads |

### 3.3 RISC-V EVL Support Status

As of early 2026, **EVL/Dovetail RISC-V support is not yet upstream** but is actively developed:

- **Dovetail for RISC-V** patches exist in the EVL mailing list and Philippe Gerum's (EVL maintainer) development trees. The patches target `linux-6.6` LTS, which aligns with SpacemiT's kernel base.
- The main EVL kernel tree is at: `git://git.evlproject.org/linux-evl.git` (branch `evl/master`)
- The EVL library: `git://git.evlproject.org/libevl.git`
- RISC-V Dovetail patches require:
  1. `arch/riscv/kernel/entry.S` — OOB entry stubs
  2. `arch/riscv/kernel/irq.c` — pipeline stage switching
  3. `arch/riscv/include/asm/dovetail.h` — arch-specific pipeline hooks
  4. FPU context save/restore for OOB threads
  5. Timer interrupt routing through Dovetail

**Current known state:**
- x86_64 and ARM64 are the primary supported architectures
- RISC-V Dovetail patches have been posted but not merged as of this writing
- SpacemiT K1 uses standard RISC-V timer/interrupt infrastructure, which is a good sign for portability

### 3.4 Key Porting Challenges

#### Challenge 1: Dovetail RISC-V Architecture Port
The Dovetail pipeline needs arch-specific hooks in the RISC-V interrupt entry path. The SpacemiT kernel uses the standard `arch/riscv/` code, so upstream RISC-V Dovetail patches should apply with minimal conflict.

**Action:** Cherry-pick or rebase RISC-V Dovetail patches from EVL development tree onto SpacemiT `v6.6.63`.

#### Challenge 2: SpacemiT K1 Custom Patches Conflict
SpacemiT's `linux-6.6` fork contains proprietary patches for:
- K1 SoC initialization and clock drivers
- Custom DTS (Device Tree Source) for Jupiter board
- Possibly modified interrupt handling for PLIC

These may conflict with Dovetail's interrupt pipeline modifications.

**Action:** Carefully audit `arch/riscv/kernel/irq.c` and `drivers/irqchip/irq-sifive-plic.c` in the SpacemiT tree for any non-standard modifications before applying Dovetail.

#### Challenge 3: FPU Context Switching
EVL OOB threads need their own FPU context. RISC-V FPU (F/D extensions) context switching in the EVL path must be verified. The K1 also supports the V (Vector) extension — EVL does not yet handle Vector register state for OOB threads.

**Mitigation:** Disable Vector extension usage in EVL threads initially. Add `CONFIG_EVL_DISABLE_VEXT` or equivalent guard.

#### Challenge 4: High-Resolution Timer
EVL requires a high-resolution clock source. The RISC-V `mtime` counter (typically 24 MHz on K1) provides the base. The `riscv_timer` driver must be compatible with Dovetail's clock pipeline.

**Action:** Verify `CONFIG_HZ=1000` and `CONFIG_HIGH_RES_TIMERS=y` in the K1 defconfig, and ensure `riscv_timer` is not bypassed by SpacemiT customizations.

#### Challenge 5: WSL2 Build Environment
Building on Windows WSL2 with the kernel source on a Windows filesystem (`/mnt/c/...`) causes:
- Slow I/O (NTFS via 9P)
- `make` case-sensitivity issues
- Symlink permission problems

**Mitigation:** Always clone and build inside the WSL2 native filesystem (e.g., `~/work/`), never under `/mnt/c/`. Our scripts enforce this.

### 3.5 Patch Strategy

We use a **three-layer patch approach**:

```
Layer 1: SpacemiT linux-6.6 v6.6.63 (base)
    ↓ apply
Layer 2: RISC-V Dovetail patches (from EVL dev tree)
    ↓ apply
Layer 3: SpacemiT K1 / Jupiter board-specific EVL fixes (our patches)
    ↓
Final: EVL-enabled kernel for Jupiter
```

Patches are stored in `patches/` as numbered `.patch` files and applied by `scripts/build/01-apply-patches.sh`.

---

## 4. Prerequisites

### Host System
- **OS:** Ubuntu 22.04 LTS (WSL2 on Windows is supported — see note below)
- **Architecture:** x86_64

### Required Packages

```bash
sudo apt-get update
sudo apt-get install -y \
  git build-essential cpio unzip rsync file bc wget make curl \
  flex bison libncurses5-dev libncursesw5-dev libssl-dev \
  dosfstools mtools device-tree-compiler u-boot-tools \
  python3 python-is-python3 python3-pip pkg-config \
  zip zlib1g-dev xz-utils

sudo pip3 install pyyaml
```

### RISC-V Cross-Compiler

```bash
# Option A: apt (Ubuntu 22.04)
sudo apt-get install gcc-riscv64-linux-gnu

# Option B: Download pre-built toolchain (recommended for reproducibility)
# See scripts/build/00-setup-env.sh for automated download
```

### ⚠️ WSL2 Path Warning

**Never** clone or build inside `/mnt/c/` or any Windows-mounted path.  
Always work in the WSL2 native filesystem:

```bash
# Good ✓
cd ~/work && git clone ...

# Bad ✗ — will cause mysterious build failures
cd /mnt/c/Users/... && git clone ...
```

Our build scripts automatically enforce this by checking `$PWD` at startup.

---

## 5. Quick-Start Build Guide

```bash
# 1. Clone this repo (on WSL2 native filesystem)
cd ~/work
git clone <this-repo-url> spacemit-xenomai
cd spacemit-xenomai

# 2. Set up environment (clones kernel + EVL, downloads toolchain)
bash scripts/build/00-setup-env.sh

# 3. Apply EVL Dovetail patches to kernel
bash scripts/build/01-apply-patches.sh

# 4. Configure kernel (merges SpacemiT defconfig + EVL fragment)
bash scripts/build/02-configure.sh

# 5. Build kernel, DTBs, and modules
bash scripts/build/03-build-kernel.sh
```

Output artefacts (in `~/work/build-k1/`):
- `arch/riscv/boot/Image` — kernel image
- `arch/riscv/boot/dts/spacemit/*.dtb` — device trees
- `modules/` — kernel modules

---

## 6. Flashing to SD Card

See [`docs/testing.md`](docs/testing.md) for full procedure.

```bash
# Identify your SD card device (e.g., /dev/sdb)
lsblk

# Flash (replace /dev/sdX with your actual device)
bash scripts/flash/flash-sdcard.sh /dev/sdX ~/work/build-k1/
```

> **Warning:** Double-check the device path. Wrong device = data loss.

---

## 7. Testing EVL on the Board

After booting the EVL kernel on Jupiter:

```bash
# Check EVL is loaded
dmesg | grep -i evl

# Run EVL latency test (requires libevl installed)
evl test latmus

# Run basic smoke test
evl check
```

Expected latency targets (Jupiter / SpacemiT K1):
- **Worst-case OOB latency:** < 50 µs (initial target)
- **Steady-state OOB latency:** < 20 µs (stretch goal)

See [`docs/testing.md`](docs/testing.md) for detailed test procedures and result logging.

---

## 8. s-aiotm Integration Targets

| Capability | Implementation Plan | EVL Primitive |
|-----------|--------------------|--------------------|
| 01 Heterogeneous protocol adaptation | CAN / RS-485 driver as EVL proxy driver | `evl_proxy`, `evl_poll` |
| 03 Real-time data bus | Shared memory ring buffer with EVL mutex | `evl_mutex`, `evl_heap` |
| 04 Closed-loop control execution | 1 kHz control loop thread | `evl_thread`, `evl_timer` |
| 08 Task scheduling | Priority-based EVL thread pool | `evl_sched_quota`, `evl_sched_tp` |

---

## 9. Known Issues & Workarounds

| Issue | Status | Workaround |
|-------|--------|-----------|
| RISC-V Dovetail not upstream | Open | Use patches from EVL dev mailing list |
| SpacemiT PLIC driver conflicts | Under investigation | Audit `irq-sifive-plic.c` in SpacemiT tree |
| Vector extension in OOB context | Not supported | Disable V-ext in EVL threads |
| WSL2 `/mnt/c/` build failures | Known | Always build in `~/work/` (WSL2 native FS) |
| `make spacemit_k1_v2_defconfig` missing EVL options | Expected | Use `02-configure.sh` to merge EVL fragment |

---

## 10. References

### EVL / Xenomai 4
- [EVL Project Homepage](https://evlproject.org/)
- [EVL Kernel Git](https://git.evlproject.org/linux-evl.git)
- [libevl Git](https://git.evlproject.org/libevl.git)
- [Dovetail Documentation](https://evlproject.org/dovetail/)
- [EVL Core Documentation](https://evlproject.org/core/)
- Philippe Gerum's EVL blog: https://xenomai.org/

### SpacemiT K1 / Milk-V Jupiter
- [SpacemiT linux-6.6 v6.6.63](https://gitee.com/spacemit-buildroot/linux-6.6-v2.1.y/tree/v6.6.63/)
- [Milk-V Jupiter Wiki](https://milkv.io/docs/jupiter)
- [SpacemiT K1 Datasheet](https://developer.spacemit.com/)

### RISC-V
- [RISC-V ISA Specification](https://riscv.org/technical/specifications/)
- [RISC-V Linux Kernel](https://git.kernel.org/pub/scm/linux/kernel/git/riscv/linux.git)

### Build Environment
- [WSL2 Kernel Build Guide](https://docs.microsoft.com/en-us/windows/wsl/)
- [RISC-V GNU Toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain)
