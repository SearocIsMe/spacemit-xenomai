# Xenomai 4 (EVL) on Milk-V Jupiter / SpacemiT K1 (RISC-V)

> **Status:** First successful build achieved — EVL kernel boots on Milk-V Jupiter (pending hardware validation).  
> **Target board:** Milk-V Jupiter (SpacemiT K1, RISC-V RV64GCV)  
> **Kernel base:** `linux-6.6` — SpacemiT fork [`v6.6.63`](https://gitee.com/spacemit-buildroot/linux-6.6-v2.1.y/tree/v6.6.63/)  
> **Real-time layer:** Xenomai 4 / EVL (Eclipse Versatile Linux)  
> **Build result:** `Kernel: arch/riscv/boot/Image is ready` (33 MB) ✅

---

## Table of Contents

1. [Project Purpose](#1-project-purpose)
2. [Repository Layout](#2-repository-layout)
3. [Background & Research Findings](#3-background--research-findings)
   - 3.1 [SpacemiT K1 SoC](#31-spacemit-k1-soc)
   - 3.2 [Xenomai 4 / EVL Architecture](#32-xenomai-4--evl-architecture)
   - 3.3 [RISC-V EVL Support Status](#33-risc-v-evl-support-status)
   - 3.4 [Key Porting Challenges](#34-key-porting-challenges)
   - 3.5 [Overlay Strategy](#35-overlay-strategy)
4. [Prerequisites](#4-prerequisites)
5. [Complete Build Guide](#5-complete-build-guide)
   - [Step 0: Clone repos and set up environment](#step-0-clone-repos-and-set-up-environment)
   - [Step 0b: Deploy kernel-overlay to linux-k1](#step-0b-deploy-kernel-overlay-to-linux-k1)
   - [Step 1: Configure kernel](#step-1-configure-kernel)
   - [Step 2: Build kernel](#step-2-build-kernel)
   - [Step 3: Create bootable SD card image](#step-3-create-bootable-sd-card-image)
6. [Flashing to SD Card](#6-flashing-to-sd-card)
7. [Testing EVL on the Board](#7-testing-evl-on-the-board)
8. [RISC-V Porting Details](#8-risc-v-porting-details)
   - 8.1 [kernel-overlay/ file map](#81-kernel-overlay-file-map)
   - 8.2 [Fixes applied to SpacemiT linux-k1](#82-fixes-applied-to-spacemit-linux-k1)
9. [s-aiotm Integration Targets](#9-s-aiotm-integration-targets)
10. [Known Issues & Workarounds](#10-known-issues--workarounds)
11. [References](#11-references)

---

## 1. Project Purpose

This repository contains **only our own scripts, configs, overlay files, and documentation** for porting Xenomai 4 (EVL) to the Milk-V Jupiter development board.

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
├── README.md                      ← This file
├── .gitignore                     ← Excludes all non-owned artefacts
│
├── docs/
│   ├── architecture.md            ← EVL dual-kernel architecture notes
│   ├── porting-notes.md           ← RISC-V specific porting details
│   └── testing.md                 ← Latency test procedures & results
│
├── configs/
│   ├── k1_evl_defconfig           ← Kernel config fragment for EVL on K1
│   └── extlinux.conf              ← Boot loader config for Jupiter
│
├── kernel-overlay/                ← Mirror of linux-k1 tree (EVL files only)
│   ├── Kconfig                    ← Top-level Kconfig (sources kernel/evl/Kconfig)
│   ├── arch/riscv/
│   │   ├── Kconfig                ← Adds HAVE_IRQ_PIPELINE / HAVE_DOVETAIL
│   │   ├── include/asm/
│   │   │   ├── dovetail.h         ← NEW: arch Dovetail hook declarations
│   │   │   ├── irq_pipeline.h     ← NEW: OOB IRQ pipeline arch interface
│   │   │   ├── irqflags.h         ← MODIFIED: pipeline-aware stall/unstall
│   │   │   ├── syscall.h          ← MODIFIED: adds syscall_get_arg0()
│   │   │   └── thread_info.h      ← MODIFIED: adds oob_thread_state
│   │   ├── include/dovetail/
│   │   │   └── thread_info.h      ← NEW: OOB thread info for RISC-V
│   │   └── kernel/
│   │       ├── Makefile           ← MODIFIED: adds irq_pipeline.o
│   │       ├── irq_pipeline.c     ← NEW: arch_do_IRQ_pipelined, arch_irq_pipeline_init
│   │       ├── smp.c              ← MODIFIED: adds ipi_irq_base, irq_send_oob_ipi
│   │       └── traps.c            ← MODIFIED: routes IRQs through Dovetail pipeline
│   ├── include/
│   │   ├── linux/
│   │   │   ├── dovetail.h         ← NEW: Dovetail pipeline API
│   │   │   ├── irq_pipeline.h     ← NEW: IRQ pipeline core header
│   │   │   ├── irqstage.h         ← NEW: IRQ stage definitions
│   │   │   ├── dmaengine.h        ← MODIFIED: adds #include <linux/dovetail.h>
│   │   │   ├── sched.h            ← PATCHED via 00b-deploy-overlay.sh (stall_bits)
│   │   │   └── sched/coredump.h   ← MODIFIED: adds MMF_DOVETAILED 31
│   │   ├── asm-generic/
│   │   │   ├── irq_pipeline.h
│   │   │   └── evl/               ← EVL generic arch headers
│   │   ├── dovetail/              ← Dovetail interface headers
│   │   ├── evl/                   ← EVL core headers
│   │   └── uapi/evl/              ← EVL user-space ABI headers
│   └── kernel/
│       ├── Makefile               ← MODIFIED: adds obj-$(CONFIG_DOVETAIL) += dovetail.o
│       ├── dovetail.c             ← NEW: Dovetail core (from linux-evl)
│       ├── smp.c                  ← MODIFIED: adds OOB IPI flush support
│       ├── irq/
│       │   ├── Kconfig            ← MODIFIED: adds IRQ_PIPELINE config
│       │   ├── Makefile           ← MODIFIED: adds pipeline objects
│       │   └── chip.c             ← MODIFIED: pipeline-aware IRQ chip
│       └── evl/                   ← EVL core subsystem source
│
└── scripts/
    ├── build/
    │   ├── 00-setup-env.sh        ← Clone kernel + EVL, set toolchain
    │   ├── 00b-deploy-overlay.sh  ← Deploy kernel-overlay/ + patch sched.h
    │   ├── 02-configure.sh        ← Merge SpacemiT defconfig + EVL fragment
    │   ├── 03-build-kernel.sh     ← Cross-compile kernel + modules
    │   └── 04-build-sdk.sh        ← Build libevl SDK (optional)
    └── flash/
        ├── flash-sdcard.sh        ← Write image to SD card (Linux host)
        ├── flash-windows.ps1      ← Write image using Win32DiskImager
        ├── make-boot-img.sh       ← Create minimal boot FAT image
        ├── make-full-sdcard-img.sh← Inject EVL kernel into bianbu-linux base image
        └── readme.md
```

> **Rule:** Only files under `docs/`, `configs/`, `kernel-overlay/`, and `scripts/` are tracked in git.  
> Kernel sources, toolchains, build outputs, and SD card images are **never** committed.

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
| RISC-V support | None | Ported here ✅ | Upstream |
| Latency (typical) | ~5–20 µs | ~5–15 µs | ~20–100 µs |
| Upstream path | No | Planned | Merged |
| User API | Xenomai POSIX skin | libevl (native) | Standard pthreads |

### 3.3 RISC-V EVL Support Status

As of early 2026, **EVL/Dovetail RISC-V support is not yet upstream** but is actively developed. This repository provides a working port onto SpacemiT K1 (linux-6.6.63):

- Dovetail interrupt pipeline functional on RISC-V
- OOB IPI via `irq_send_oob_ipi` / `ipi_irq_base`
- `arch_do_IRQ_pipelined`, `arch_irq_pipeline_init` implemented
- `MMF_DOVETAILED` mm flag bit 31 added
- `syscall_get_arg0` for RISC-V (`regs->orig_a0`)
- `stall_bits` in `task_struct` for per-task IRQ pipeline stall state
- EVL-enabled kernel Image built successfully: **33 MB**

### 3.4 Key Porting Challenges

#### Challenge 1: Dovetail RISC-V Architecture Port
The Dovetail pipeline needs arch-specific hooks in the RISC-V interrupt entry path.

**Resolved:** `arch/riscv/kernel/irq_pipeline.c` created with `arch_do_IRQ_pipelined` and `arch_irq_pipeline_init`. `arch/riscv/kernel/traps.c` patched to route IRQs through the pipeline.

#### Challenge 2: Missing kernel/dovetail.c compilation
`kernel/dovetail.c` existed in the tree but `kernel/Makefile` had no entry to compile it.

**Resolved:** Added `obj-$(CONFIG_DOVETAIL) += dovetail.o` to `kernel/Makefile`.

#### Challenge 3: Missing arch-specific definitions
- `MMF_DOVETAILED` bit 31 missing from `include/linux/sched/coredump.h`
- `syscall_get_arg0` missing from `arch/riscv/include/asm/syscall.h`
- `stall_bits` field missing from `struct task_struct` in `include/linux/sched.h`

**Resolved:** All three added (see [Section 8.2](#82-fixes-applied-to-spacemit-linux-k1)).

#### Challenge 4: WSL2 Build Environment
Building on Windows WSL2 with the kernel source on a Windows filesystem (`/mnt/c/...`) causes slow I/O and `make` failures.

**Mitigation:** Always clone and build inside the WSL2 native filesystem (`~/work/`). Build scripts enforce this.

### 3.5 Overlay Strategy

All EVL/Dovetail modifications are maintained in `kernel-overlay/` — a directory that exactly mirrors the kernel source tree. Deployment is a single `rsync` command. No patch files or rebase required.

```
kernel-overlay/           (tracked in git)
    ↓ rsync by 00b-deploy-overlay.sh
~/work/linux-k1/          (not tracked, SpacemiT kernel tree)
    ↓ 02-configure.sh
~/work/build-k1/.config   (EVL + K1 merged config)
    ↓ 03-build-kernel.sh
~/work/build-k1/arch/riscv/boot/Image  (33 MB EVL kernel)
    ↓ make-full-sdcard-img.sh
~/work/evl-sdcard-k1-YYYYMMDD.img      (1.4 GB bootable SD image)
```

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
  zip zlib1g-dev xz-utils fdisk kpartx

sudo pip3 install pyyaml
```

### RISC-V Cross-Compiler

```bash
# Ubuntu 22.04
sudo apt-get install gcc-riscv64-linux-gnu

# Verify
riscv64-linux-gnu-gcc --version
# riscv64-linux-gnu-gcc (Ubuntu 12.3.0-...) 12.x.x
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

---

## 5. Complete Build Guide

This section documents the **exact steps** used to produce a working EVL-enabled kernel and SD card image for the Milk-V Jupiter board.

### Directory layout assumed

```
~/work/
├── linux-k1/          ← SpacemiT kernel source (cloned by 00-setup-env.sh)
├── linux-evl/         ← EVL reference kernel (cloned by 00-setup-env.sh)
├── build-k1/          ← Out-of-tree build directory
└── evl-sdcard-k1-YYYYMMDD.img   ← Output SD card image
```

---

### Step 0: Clone repos and set up environment

```bash
cd ~/work
git clone <this-repo-url> spacemit-xenomai
cd spacemit-xenomai

# Clone SpacemiT linux-k1, EVL reference tree, and set up toolchain
bash scripts/build/00-setup-env.sh
```

This script clones:
- `~/work/linux-k1` — SpacemiT linux-6.6 v6.6.63
- `~/work/linux-evl` — EVL upstream reference (for header comparison)

---

### Step 0b: Deploy kernel-overlay to linux-k1

The `kernel-overlay/` directory mirrors the linux-k1 source tree and contains all new and modified files required for EVL/Dovetail support on RISC-V.

```bash
bash scripts/build/00b-deploy-overlay.sh
```

This script does two things:

**a) rsync all overlay files into `~/work/linux-k1/`:**

```
kernel-overlay/arch/riscv/Kconfig                        → arch/riscv/Kconfig
kernel-overlay/arch/riscv/include/asm/dovetail.h         → arch/riscv/include/asm/dovetail.h
kernel-overlay/arch/riscv/include/asm/irq_pipeline.h     → arch/riscv/include/asm/irq_pipeline.h
kernel-overlay/arch/riscv/include/asm/irqflags.h         → arch/riscv/include/asm/irqflags.h
kernel-overlay/arch/riscv/include/asm/syscall.h          → arch/riscv/include/asm/syscall.h
kernel-overlay/arch/riscv/include/asm/thread_info.h      → arch/riscv/include/asm/thread_info.h
kernel-overlay/arch/riscv/include/dovetail/thread_info.h → arch/riscv/include/dovetail/thread_info.h
kernel-overlay/arch/riscv/kernel/Makefile                → arch/riscv/kernel/Makefile
kernel-overlay/arch/riscv/kernel/irq_pipeline.c          → arch/riscv/kernel/irq_pipeline.c
kernel-overlay/arch/riscv/kernel/smp.c                   → arch/riscv/kernel/smp.c
kernel-overlay/arch/riscv/kernel/traps.c                 → arch/riscv/kernel/traps.c
kernel-overlay/include/linux/dovetail.h                  → include/linux/dovetail.h
kernel-overlay/include/linux/irq_pipeline.h              → include/linux/irq_pipeline.h
kernel-overlay/include/linux/irqstage.h                  → include/linux/irqstage.h
kernel-overlay/include/linux/dmaengine.h                 → include/linux/dmaengine.h
kernel-overlay/include/linux/sched/coredump.h            → include/linux/sched/coredump.h
kernel-overlay/include/asm-generic/irq_pipeline.h        → include/asm-generic/irq_pipeline.h
kernel-overlay/include/asm-generic/evl/                  → include/asm-generic/evl/
kernel-overlay/include/dovetail/                         → include/dovetail/
kernel-overlay/include/evl/                              → include/evl/
kernel-overlay/include/uapi/evl/                         → include/uapi/evl/
kernel-overlay/kernel/Makefile                           → kernel/Makefile
kernel-overlay/kernel/dovetail.c                         → kernel/dovetail.c
kernel-overlay/kernel/smp.c                              → kernel/smp.c
kernel-overlay/kernel/irq/                               → kernel/irq/
kernel-overlay/kernel/evl/                               → kernel/evl/
kernel-overlay/Kconfig                                   → Kconfig
```

**b) Patch `include/linux/sched.h` in-place** — adds `stall_bits` to `task_struct`:

```c
// Inserted after softirq_disable_cnt in struct task_struct:
#ifdef CONFIG_IRQ_PIPELINE
    unsigned long   stall_bits;
#endif
```

This is done as a targeted in-place injection rather than a full file replacement, since `sched.h` is a large base-kernel file that changes frequently.

---

### Step 1: Configure kernel

```bash
bash scripts/build/02-configure.sh
```

This merges the SpacemiT base defconfig with the EVL config fragment:

```bash
# Internally runs:
make ARCH=riscv O=~/work/build-k1 spacemit_k1_v2_defconfig
./scripts/kconfig/merge_config.sh -m \
    ~/work/build-k1/.config \
    configs/k1_evl_defconfig
make ARCH=riscv O=~/work/build-k1 olddefconfig
```

Key EVL options enabled by `configs/k1_evl_defconfig`:
```
CONFIG_IRQ_PIPELINE=y
CONFIG_DOVETAIL=y
CONFIG_EVL=y
CONFIG_EVL_SCHED_QUOTA=y
CONFIG_EVL_SCHED_TP=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ_1000=y
```

Verify after configure:
```bash
grep -E "CONFIG_(DOVETAIL|EVL|IRQ_PIPELINE)" ~/work/build-k1/.config
# CONFIG_IRQ_PIPELINE=y
# CONFIG_DOVETAIL=y
# CONFIG_EVL=y
```

---

### Step 2: Build kernel

```bash
bash scripts/build/03-build-kernel.sh
# or directly:
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
     LOCALVERSION= O=~/work/build-k1 -j$(nproc) Image modules dtbs \
     2>&1 | tee /tmp/k1_build.log
```

> **Important:** Do **not** pipe through `head -N` — this causes SIGPIPE to kill `make` during the linker stage (LD vmlinux). Use `tail -5` or `tee` only.

Expected output on success:
```
  LD      vmlinux
  NM      System.map
  SORTTAB vmlinux
  OBJCOPY arch/riscv/boot/Image
  Kernel: arch/riscv/boot/Image is ready
```

Output artefacts in `~/work/build-k1/`:
- `arch/riscv/boot/Image` — kernel image (33 MB)
- `arch/riscv/boot/dts/spacemit/k1-x_milkv-jupiter.dtb` — Jupiter device tree
- `**/*.ko` — kernel modules

---

### Step 3: Create bootable SD card image

The `make-full-sdcard-img.sh` script injects the EVL kernel into a base Bianbu Linux image (SpacemiT's official rootfs):

```bash
sudo bash scripts/flash/make-full-sdcard-img.sh \
    --kernel  ~/work/build-k1/arch/riscv/boot/Image \
    --dtb     ~/work/build-k1/arch/riscv/boot/dts/spacemit/k1-x_milkv-jupiter.dtb \
    --modules ~/work/build-k1 \
    --output  ~/work/evl-sdcard-k1-$(date +%Y%m%d).img
```

> The script downloads a base Bianbu Linux image (~1.4 GB) if not already cached, then:
> 1. Mounts the base image partitions via `kpartx`
> 2. Replaces `bootfs/Image` with the EVL kernel
> 3. Updates `bootfs/*.dtb` with the new Jupiter DTB
> 4. Installs EVL modules into `rootfs/lib/modules/6.6.63/`
> 5. Configures serial console (`ttyS0`) and HDMI console (`tty1`) gettys
> 6. Sets root password to `root`
> 7. Disables Weston autostart
> 8. Writes the final image

Output: `~/work/evl-sdcard-k1-YYYYMMDD.img` (~1.4 GB)

---

## 6. Flashing to SD Card

```bash
# Identify your SD card device
lsblk

# Flash the image (replace /dev/sdX with your actual device — DOUBLE CHECK!)
sudo dd if=~/work/evl-sdcard-k1-$(date +%Y%m%d).img \
        of=/dev/sdX \
        bs=4M status=progress conv=fsync

# Eject
sync && sudo eject /dev/sdX
```

> **Warning:** Wrong device = permanent data loss. Verify with `lsblk` before flashing.

**Windows (PowerShell):**
```powershell
.\scripts\flash\flash-windows.ps1 -Image "evl-sdcard-k1-*.img" -Drive "E:"
```
Or use [balenaEtcher](https://etcher.balena.io/) / [Win32DiskImager](https://win32diskimager.org/).

---

## 7. Testing EVL on the Board

Insert the SD card and boot the Milk-V Jupiter. Connect serial console on `/dev/ttyUSB0` at 115200 baud.

```bash
# On the board — check EVL initialised
dmesg | grep -i "evl\|dovetail\|oob"

# Expected output includes:
# [    0.xxx] Dovetail: interrupt pipeline enabled
# [    0.xxx] EVL: core started

# Check EVL ABI
cat /proc/evl/version

# Run EVL latency test (requires libevl installed on rootfs)
evl check
evl test latmus -t irq
```

Expected latency targets (Jupiter / SpacemiT K1, initial):
- **Worst-case OOB latency:** < 50 µs
- **Steady-state OOB latency:** < 20 µs (stretch goal)

See [`docs/testing.md`](docs/testing.md) for detailed test procedures and result logging.

---

## 8. RISC-V Porting Details

### 8.1 kernel-overlay/ file map

The complete set of files that must be deployed to `~/work/linux-k1/` to enable EVL/Dovetail on RISC-V:

| File in kernel-overlay/ | Change type | Purpose |
|---|---|---|
| `arch/riscv/Kconfig` | Modified | Adds `select HAVE_IRQ_PIPELINE` and `select HAVE_DOVETAIL` |
| `arch/riscv/include/asm/dovetail.h` | **New** | Arch Dovetail hook declarations (`arch_enable_oob_stage` etc.) |
| `arch/riscv/include/asm/irq_pipeline.h` | **New** | OOB IRQ pipeline arch interface (`arch_irq_stage_*`) |
| `arch/riscv/include/asm/irqflags.h` | Modified | Pipeline-aware `arch_local_irq_save/restore` with stall |
| `arch/riscv/include/asm/syscall.h` | Modified | Adds `syscall_get_arg0()` returning `regs->orig_a0` |
| `arch/riscv/include/asm/thread_info.h` | Modified | Adds `oob_thread_state` to `struct thread_info` |
| `arch/riscv/include/dovetail/thread_info.h` | **New** | OOB thread state structure for RISC-V |
| `arch/riscv/kernel/Makefile` | Modified | Adds `obj-$(CONFIG_IRQ_PIPELINE) += irq_pipeline.o` |
| `arch/riscv/kernel/irq_pipeline.c` | **New** | `arch_do_IRQ_pipelined()`, `arch_irq_pipeline_init()` |
| `arch/riscv/kernel/smp.c` | Modified | Adds `ipi_irq_base`, `irq_send_oob_ipi()` |
| `arch/riscv/kernel/traps.c` | Modified | Routes IRQs through Dovetail pipeline stages |
| `include/linux/sched/coredump.h` | Modified | Adds `#define MMF_DOVETAILED 31` |
| `include/linux/dmaengine.h` | Modified | Adds `#include <linux/dovetail.h>` |
| `kernel/Makefile` | Modified | Adds `obj-$(CONFIG_DOVETAIL) += dovetail.o` |
| `kernel/dovetail.c` | **New** (from EVL) | Dovetail core implementation |
| `kernel/smp.c` | Modified | Adds `smp_flush_oob_call_function_queue()` |
| `kernel/irq/Kconfig` | Modified | Adds `IRQ_PIPELINE` and `DOVETAIL` config symbols |
| `kernel/irq/Makefile` | Modified | Adds pipeline-aware IRQ chip objects |
| `kernel/irq/chip.c` | Modified | Pipeline-aware IRQ chip operations |
| `include/linux/sched.h` | **Patched in-place** | Adds `stall_bits` to `struct task_struct` |

### 8.2 Fixes applied to SpacemiT linux-k1

These are the critical bugs fixed during the porting process, all reflected in `kernel-overlay/`:

#### Fix 1: `kernel/dovetail.c` never compiled
`kernel/Makefile` had no entry for `dovetail.c` despite the file being present.
```makefile
# kernel/Makefile line 110:
obj-$(CONFIG_DOVETAIL) += dovetail.o   # ← added
```
**Symptom:** `dovetail_call_mayday` undefined reference at link time.

#### Fix 2: `MMF_DOVETAILED` bit 31 missing
`include/linux/sched/coredump.h` only defined mm flag bits up to 30.
```c
// include/linux/sched/coredump.h line 95:
#define MMF_DOVETAILED   31   /* mm belongs to a dovetailed process */
```
**Symptom:** `'MMF_DOVETAILED' undeclared` in `kernel/dovetail.c:48`.

#### Fix 3: `syscall_get_arg0` missing on RISC-V
EVL's `include/linux/dovetail.h:240` calls `syscall_get_arg0()`. arm64 defined it; RISC-V did not.
```c
// arch/riscv/include/asm/syscall.h:
static inline unsigned long syscall_get_arg0(struct task_struct *task,
                                              struct pt_regs *regs)
{
    return regs->orig_a0;   // first syscall arg on RISC-V
}
```
**Symptom:** `'syscall_get_arg0' undeclared` in `include/linux/dovetail.h:240`.

#### Fix 4: `stall_bits` missing from `task_struct`
EVL's IRQ pipeline requires `stall_bits` per task for pipeline stall state tracking.
```c
// include/linux/sched.h — injected by 00b-deploy-overlay.sh:
#ifdef CONFIG_IRQ_PIPELINE
    unsigned long   stall_bits;
#endif
```
**Symptom:** `error: 'struct task_struct' has no member named 'stall_bits'`.

#### Fix 5: `#include <linux/irqstage.h>` missing from `kernel/sched/core.c`

`linux-k1`'s `core.c` does not include `irq_pipeline.h` or `dovetail.h` transitively, unlike the EVL
reference tree. The header is injected by `00b-deploy-overlay.sh`:

```c
// kernel/sched/core.c — added just before #include <linux/highmem.h>:
#ifdef CONFIG_IRQ_PIPELINE
#include <linux/irqstage.h>
#endif
```

**Symptom without fix:** `implicit declaration of function 'init_task_stall_bits'` compile error.

---

#### Fix 5b (REVERTED — was a regression): `init_task_stall_bits(p)` in `__sched_fork()`

**History:** An earlier attempt added a call to `init_task_stall_bits(p)` at the end of `__sched_fork()`
to set `INBAND_STALL_BIT=1` for every new task. This turned out to cause a **boot hang** — the kernel
froze at the Bianbu splash screen with no further output.

**Root cause:** `INBAND_STALL_BIT=1` means *in-band IRQs are disabled*. Setting it on every new task
from birth makes `inband_irqs_disabled()` return `true` for all tasks permanently, causing the IRQ
pipeline to treat them as IRQ-stalled → scheduler deadlock during early boot.

**Correct behavior:** `task_struct.stall_bits` is zero-initialized. `INBAND_STALL_BIT=0` means
*in-band IRQs are enabled*, which is the correct default for newly forked tasks. The EVL reference
tree (`linux-evl`) does **not** call `init_task_stall_bits()` in `__sched_fork()` either —
the zero-initialized value is intentional.

**Proof:** The Apr 1 kernel build (without this call) booted successfully on Milk-V Jupiter;
the Apr 3 kernel build (with this call) hung at the Bianbu splash.

**Fix:** Reverted Apr 2026 — `init_task_stall_bits(p)` removed from `__sched_fork()` and
removed from the `00b-deploy-overlay.sh` injector.

---

## 9. s-aiotm Integration Targets

| Capability | Implementation Plan | EVL Primitive |
|-----------|--------------------|--------------------|
| 01 Heterogeneous protocol adaptation | CAN / RS-485 driver as EVL proxy driver | `evl_proxy`, `evl_poll` |
| 03 Real-time data bus | Shared memory ring buffer with EVL mutex | `evl_mutex`, `evl_heap` |
| 04 Closed-loop control execution | 1 kHz control loop thread | `evl_thread`, `evl_timer` |
| 08 Task scheduling | Priority-based EVL thread pool | `evl_sched_quota`, `evl_sched_tp` |

---

## 10. Known Issues & Workarounds

| Issue | Status | Workaround |
|-------|--------|-----------|
| RISC-V Dovetail not upstream | Open | Use `kernel-overlay/` in this repo |
| Hardware EVL boot test pending | Pending | Flash `evl-sdcard-k1-*.img` and test |
| Vector extension in OOB context | Not supported | Disable V-ext in EVL threads |
| WSL2 `/mnt/c/` build failures | Known | Always build in `~/work/` (WSL2 native FS) |
| `head -N` pipe kills `make LD vmlinux` | Fixed | Do not pipe build output through `head` |

---

## 11. References

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
