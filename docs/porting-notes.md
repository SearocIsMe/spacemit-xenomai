# Porting Notes: EVL Dovetail on SpacemiT K1 (RISC-V)

## Overview

This document captures the detailed technical steps, decisions, and findings for porting Xenomai 4 / EVL to the SpacemiT K1 RISC-V SoC. It is intended as a living document — update it as the port progresses.

---

## 1. Source Trees

### 1.1 SpacemiT Kernel Base

```
Repo   : https://gitee.com/spacemit-buildroot/linux-6.6-v2.1.y.git
Branch : v6.6.63
Config : spacemit_k1_v2_defconfig
```

Key SpacemiT-specific directories to be aware of:
- `arch/riscv/` — standard RISC-V arch code + SpacemiT additions
- `drivers/clk/spacemit/` — K1 clock driver
- `drivers/pinctrl/spacemit/` — K1 pin controller
- `arch/riscv/boot/dts/spacemit/` — Jupiter board DTS

### 1.2 EVL Kernel Reference Tree

```
Repo (denx.de mirror) : https://source.denx.de/Xenomai/xenomai4/linux-evl.git
Repo (upstream)       : https://git.evlproject.org/linux-evl.git
Tag (preferred)       : v6.6.63-evl2-rebase   ← EVL patches rebased on v6.6.63
Branch (upstream)     : evl/master
```

> **Note:** `git.evlproject.org` is frequently unreachable. Use the `source.denx.de` mirror as the primary source.
> The tag `v6.6.63-evl2-rebase` on `source.denx.de` exactly matches the SpacemiT kernel base (v6.6.63) and is the best reference for cherry-picking Dovetail patches.

This tree contains the full EVL implementation including Dovetail. We use it as a **reference** to cherry-pick RISC-V Dovetail patches onto the SpacemiT base.

Key EVL-specific directories:
- `kernel/evl/` — EVL core (scheduler, clock, heap, primitives)
- `kernel/dovetail/` — Dovetail pipeline core
- `arch/riscv/kernel/` — RISC-V Dovetail arch hooks
- `arch/riscv/include/asm/dovetail.h` — RISC-V Dovetail header
- `include/linux/dovetail.h` — Dovetail API
- `include/linux/irq_pipeline.h` — IRQ pipeline API

### 1.3 libevl (Userspace)

```
Repo (denx.de mirror) : https://source.denx.de/Xenomai/xenomai4/libevl.git
Repo (upstream)       : https://git.evlproject.org/libevl.git
Branch                : master
```

> **Note:** `git.evlproject.org` is frequently unreachable. Use the `source.denx.de` mirror as the primary source.

Provides the userspace API for EVL threads, timers, mutexes, etc. Must be cross-compiled for RISC-V and installed on the target rootfs.

---

## 2. Obtaining Dovetail RISC-V Patches

As of early 2026, RISC-V Dovetail patches are not in the upstream EVL tree's stable branch. Here is how to find and extract them:

### Method A: From EVL Mailing List

The EVL mailing list archives are at: https://xenomai.org/pipermail/xenomai/

Search for subjects containing "riscv" and "dovetail". Download the patch series and save to `patches/`.

### Method B: From EVL Development Branch

```bash
cd ~/work/linux-evl

# List RISC-V related commits
git log --oneline v6.6..HEAD -- arch/riscv/ | grep -i "dovetail\|pipeline\|evl\|oob"

# Generate patches for RISC-V Dovetail changes
git format-patch v6.6..HEAD \
  --output-directory ~/work/spacemit-xenomai/patches/ \
  -- \
  arch/riscv/ \
  include/asm-generic/dovetail.h \
  include/linux/dovetail.h \
  include/linux/irq_pipeline.h \
  kernel/dovetail/ \
  kernel/evl/
```

### Method C: Using gen-patch.sh

```bash
bash scripts/patch/gen-patch.sh \
  --tree ~/work/linux-evl \
  --from v6.6 \
  --grep "riscv.*dovetail\|dovetail.*riscv"
```

---

## 3. Patch Application Procedure

### 3.1 Preparation

```bash
cd ~/work/linux-k1

# Verify clean state
git status
git log --oneline -5

# Create working branch
git checkout -b evl-port-$(date +%Y%m%d)
```

### 3.2 Applying Dovetail Core Patches

Apply in this order:

1. **Dovetail core infrastructure** (`kernel/dovetail/`, `include/linux/dovetail.h`)
2. **IRQ pipeline** (`include/linux/irq_pipeline.h`, `kernel/irq/`)
3. **RISC-V arch hooks** (`arch/riscv/`)
4. **EVL core** (`kernel/evl/`)
5. **EVL drivers** (`drivers/evl/`)

```bash
# Check if a patch applies cleanly
git apply --check patches/0001-dovetail-core.patch

# Apply with 3-way merge fallback
git apply --3way patches/0001-dovetail-core.patch
```

### 3.3 Expected Conflict Areas

Based on analysis of the SpacemiT kernel tree, the following files are likely to have conflicts:

| File | Reason | Resolution Strategy |
|------|--------|---------------------|
| `arch/riscv/kernel/entry.S` | SpacemiT may have custom exception handling | Manually merge — preserve SpacemiT SoC init, add Dovetail OOB stubs |
| `arch/riscv/kernel/irq.c` | SpacemiT PLIC customizations | Add Dovetail pipeline dispatch around existing IRQ dispatch |
| `arch/riscv/include/asm/thread_info.h` | Dovetail adds OOB thread flags | Add EVL flags without removing SpacemiT additions |
| `kernel/sched/core.c` | Dovetail hooks into scheduler | Usually clean — Dovetail uses well-defined hooks |

### 3.4 Verifying the Patch

After applying all patches, verify the Dovetail infrastructure is present:

```bash
# Check key files exist
ls arch/riscv/include/asm/dovetail.h
ls include/linux/dovetail.h
ls kernel/dovetail/
ls kernel/evl/

# Check Kconfig options are available
grep -r "DOVETAIL\|EVL_CORE" arch/riscv/Kconfig kernel/Kconfig* 2>/dev/null | head -20
```

---

## 4. Kernel Configuration Details

### 4.1 Starting Point

```bash
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=~/work/build-k1 spacemit_k1_v2_defconfig
```

### 4.2 Required EVL Options

These must be enabled (see `configs/k1_evl_defconfig`):

```
CONFIG_DOVETAIL=y
CONFIG_IRQ_PIPELINE=y
CONFIG_EVL_CORE=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ_1000=y
CONFIG_PREEMPT=y
```

### 4.3 Incompatible Options

These must be **disabled**:

```
# CONFIG_PREEMPT_RT is not set      ← mutually exclusive with Dovetail
# CONFIG_LOCKDEP is not set         ← severe overhead, breaks RT
# CONFIG_DEBUG_SPINLOCK is not set  ← overhead
```

### 4.4 Verifying Configuration

```bash
# After running 02-configure.sh, check:
grep "CONFIG_DOVETAIL\|CONFIG_EVL\|CONFIG_IRQ_PIPELINE" ~/work/build-k1/.config
```

Expected output:
```
CONFIG_DOVETAIL=y
CONFIG_IRQ_PIPELINE=y
CONFIG_EVL_CORE=y
CONFIG_EVL_SCHED_QUOTA=y
CONFIG_EVL_SCHED_TP=y
```

---

## 5. Build Troubleshooting

### 5.1 Common Build Errors

#### Error: `undefined reference to 'dovetail_*'`
**Cause:** Dovetail patches not applied, or `CONFIG_DOVETAIL` not set.  
**Fix:** Re-run `01-apply-patches.sh` and `02-configure.sh`.

#### Error: `arch/riscv/kernel/entry.S: no such instruction`
**Cause:** Dovetail adds new assembly macros that the assembler doesn't recognize.  
**Fix:** Ensure the cross-compiler version supports the RISC-V ISA extensions used. Use GCC ≥ 12 for full RV64GCV support.

#### Error: `make: /mnt/c/...: Permission denied` or `Makefile:...: *** mixed implicit and normal rules`
**Cause:** Building on Windows NTFS filesystem via WSL2.  
**Fix:** Move the entire build to `~/work/` (WSL2 native ext4 filesystem).

#### Error: `scripts/kconfig/merge_config.sh: not found`
**Cause:** Kernel source not fully cloned (shallow clone missing scripts).  
**Fix:** `git fetch --unshallow` in the kernel directory, or use `--depth=0` when cloning.

### 5.2 WSL2-Specific Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Extremely slow build | Source on `/mnt/c/` (NTFS) | Move to `~/work/` |
| `make` reports wrong timestamps | NTFS timestamp resolution | Build on ext4 |
| Symlinks fail | NTFS doesn't support symlinks by default | Build on ext4 |
| `python3` not found | WSL2 PATH issue | `sudo apt install python-is-python3` |

---

## 6. RISC-V Dovetail Architecture Details

### 6.1 OOB Entry Stub

Dovetail requires an OOB entry stub in `arch/riscv/kernel/entry.S`. The stub:

1. Is entered before the normal Linux IRQ handler
2. Saves only the registers needed for OOB dispatch (not full context)
3. Calls `irq_pipeline_oob_handle()` 
4. If the IRQ was consumed by EVL, returns immediately
5. Otherwise, falls through to normal Linux IRQ handling

```asm
/* Conceptual — actual implementation in Dovetail patch */
SYM_CODE_START(handle_exception)
    /* ... save context ... */
#ifdef CONFIG_IRQ_PIPELINE
    call    irq_pipeline_oob_handle    /* EVL gets first shot */
    bnez    a0, .Lirq_consumed         /* if EVL handled it, done */
#endif
    call    do_irq                     /* normal Linux path */
.Lirq_consumed:
    /* ... restore context ... */
SYM_CODE_END(handle_exception)
```

### 6.2 Thread Info Flags

Dovetail adds per-thread flags to `struct thread_info`:

```c
/* Added by Dovetail to arch/riscv/include/asm/thread_info.h */
#ifdef CONFIG_DOVETAIL
    struct oob_thread_state oob_state;  /* EVL OOB thread state */
#endif
```

### 6.3 FPU Context for OOB Threads

RISC-V FPU state (F/D registers) must be saved/restored when switching between OOB and in-band contexts. Dovetail hooks into `arch/riscv/kernel/fpu.S` for this.

**Current status:** Under investigation. The K1's FPU implementation follows standard RISC-V, so upstream Dovetail FPU patches should apply.

---

## 7. Progress Log

| Date | Action | Result |
|------|--------|--------|
| 2026-03-30 | Project initialized, research documented | ✅ Done |
| TBD | Obtain RISC-V Dovetail patches | ⏳ Pending |
| TBD | Apply patches to SpacemiT v6.6.63 | ⏳ Pending |
| TBD | First kernel build attempt | ⏳ Pending |
| TBD | Boot test on Jupiter | ⏳ Pending |
| TBD | EVL latency measurement | ⏳ Pending |
