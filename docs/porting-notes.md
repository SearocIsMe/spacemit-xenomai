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

> **Status (2026-03-30):** RISC-V Dovetail arch hooks are **not yet present** in any
> stable EVL branch on `source.denx.de`. The `v6.6.63-evl2-rebase` tag contains
> `kernel/dovetail/`, `kernel/evl/`, `include/linux/dovetail.h`, and
> `include/linux/irq_pipeline.h` — but **no** `arch/riscv/` Dovetail hooks and
> **no** `include/asm-generic/dovetail.h`. RISC-V Dovetail support must be obtained
> from the EVL mailing list or written from scratch.

### Method A: From EVL Mailing List (Recommended)

The EVL mailing list archives are at: https://xenomai.org/pipermail/xenomai/

Search for subjects containing "riscv" and "dovetail". Download the patch series
and save to `patches/`. As of early 2026 this is the only source for RISC-V
Dovetail arch hooks.

### Method B: From EVL Development Branch (if RISC-V support lands upstream)

Once RISC-V Dovetail is merged into an EVL stable branch, use `gen-patch.sh`:

```bash
# First unshallow the EVL tree (needed for format-patch)
cd ~/work/linux-evl
git fetch --unshallow

# List RISC-V related commits
git log --oneline v6.6.63..HEAD -- arch/riscv/ | grep -i "dovetail\|pipeline\|evl\|oob"
```

### Method C: Using gen-patch.sh

```bash
# Automatically handles unshallow, defaults base to v6.6.63
bash scripts/patch/gen-patch.sh \
  --tree ~/work/linux-evl \
  --from v6.6.63

# Or filter to only RISC-V Dovetail commits
bash scripts/patch/gen-patch.sh \
  --tree ~/work/linux-evl \
  --from v6.6.63 \
  --grep "riscv.*dovetail\|dovetail.*riscv"
```

> **Note:** `gen-patch.sh` will automatically unshallow the repo if needed.
> The `--unshallow` fetch downloads the full kernel history (~1 GB) and takes
> several minutes.

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
| 2026-03-30 | `00-setup-env.sh`: fixed EVL clone — use `source.denx.de` mirror, tag `v6.6.63-evl2-rebase` | ✅ Done |
| 2026-03-30 | Confirmed: `v6.6.63-evl2-rebase` has `kernel/evl/` + `kernel/dovetail/` but **no** `arch/riscv/` Dovetail hooks | ✅ Investigated |
| 2026-03-30 | RISC-V Dovetail arch hooks not yet in any stable EVL branch — must source from mailing list | ⚠️ Blocked |
| 2026-03-30 | Built full SD card image `evl-sdcard-k1-20260331.img` via `make-full-sdcard-img.sh` | ✅ Done |
| 2026-04-01 | Boot test on Jupiter (Milk-V) with HDMI display: Bianbu icon ✅, Bianbu load ✅, terminal ✅ | ✅ **Booted** |
| 2026-04-01 | EVL verification on Jupiter: `dmesg\|grep evl` empty, `/sys/devices/virtual/evl` absent, `evl check` → not found | ❌ **EVL absent** — see §8 |
| 2026-04-01 | Wrote RISC-V Dovetail arch hooks from scratch (`patches/0002-riscv-dovetail-arch-hooks.patch`) | ✅ Done |
| 2026-04-01 | Applied `0001`+`0002`+`0003` patches; fixed 14 build errors (see §10) | ✅ Done |
| 2026-04-01 | **Kernel build succeeded** — `arch/riscv/boot/Image` (36 MB) | ✅ **BUILD OK** |
| 2026-04-01 | Generated `patches/0004-riscv-evl-build-fixes.patch` capturing all build-fix changes | ✅ Done |
| 2026-04-02 | **EVL kernel boots on Jupiter** — DRM/HDMI init, framebuffer console, ext4 mount, udev, init all OK | ✅ **BOOTS** |
| 2026-04-02 | Added `tty1` getty to rootfs `/etc/inittab` — HDMI login prompt now appears | ✅ Done |
| 2026-04-02 | Fixed `arch_irqs_virtual_to_native_flags` inversion (RISC-V SR_IE semantics opposite to ARM64 PSR_I_BIT) | ✅ Fixed |
| TBD | Verify EVL core loaded (`dmesg \| grep -i evl`, `evl check`) | ⏳ Pending |
| TBD | EVL latency measurement (`evl run latmus -T 60 -c 1`) | ⏳ Pending |

---

## 8. Root-Cause Analysis: EVL Absent from Current Image (2026-04-01)

### 8.1 Symptom

On Jupiter, after booting `evl-sdcard-k1-20260331.img`:

```
# dmesg | grep -i evl
(no output)
# ls /sys/devices/virtual/evl
ls: /sys/devices/virtual/evl: No such file or directory
# evl check
/bin/sh: evl: not found
```

### 8.2 Root Cause

The patch `patches/0001-evl-dovetail-from-filesystem-diff.patch` was generated
from a filesystem diff between the EVL tree (`linux-evl`) and the SpacemiT tree
(`linux-k1`). Inspection of the patch shows it contains **only**:

```
kernel/evl/*          ← EVL core (scheduler, clock, heap, etc.)
include/linux/dovetail.h
include/linux/irq_pipeline.h
```

It contains **no `arch/riscv/` files at all**.

### 8.3 Why This Matters

`CONFIG_DOVETAIL` in `kernel/Kconfig` has the dependency:

```
config DOVETAIL
    bool "..."
    depends on HAVE_DOVETAIL
```

`HAVE_DOVETAIL` is set by the architecture's `arch/riscv/Kconfig` — specifically
by a line like:

```
select HAVE_DOVETAIL
```

which is added by the RISC-V Dovetail arch patch. Without that line, `DOVETAIL`
is invisible in Kconfig and silently ignored. The `02-configure.sh` script
attempts to set `CONFIG_DOVETAIL=y` but `olddefconfig` drops it because the
symbol doesn't exist. The resulting kernel is a plain SpacemiT kernel with no
EVL infrastructure whatsoever.

### 8.4 What Is Missing

The following files must be added/modified by the RISC-V Dovetail arch patch:

| File | What it does |
|------|-------------|
| `arch/riscv/Kconfig` | Add `select HAVE_DOVETAIL` |
| `arch/riscv/include/asm/dovetail.h` | RISC-V OOB thread state, FPU hooks |
| `arch/riscv/include/asm/thread_info.h` | Add `struct oob_thread_state oob_state` |
| `arch/riscv/kernel/entry.S` | OOB IRQ entry stub before normal IRQ dispatch |
| `arch/riscv/kernel/irq.c` | Dovetail pipeline dispatch |
| `arch/riscv/kernel/process.c` | OOB context switch hooks |
| `arch/riscv/kernel/fpu.S` | FPU save/restore for OOB↔in-band switches |
| `include/asm-generic/dovetail.h` | Generic Dovetail arch fallback header |

None of these are present in `v6.6.63-evl2-rebase` on `source.denx.de`.

### 8.5 Confirmed Build Config Behaviour

Even though `configs/k1_evl_defconfig` sets `CONFIG_DOVETAIL=y`, the kernel
`make olddefconfig` step silently drops it because `HAVE_DOVETAIL` is not
selected. The built kernel is therefore identical to a plain SpacemiT kernel.

To verify this on the running Jupiter:

```bash
# Check if DOVETAIL was actually compiled in
zcat /proc/config.gz | grep -E "DOVETAIL|EVL|IRQ_PIPELINE"
# Expected (bad): all lines show "# CONFIG_... is not set" or are absent
# Expected (good, after fix): CONFIG_DOVETAIL=y, CONFIG_EVL_CORE=y
```

---

## 9. Next Steps: Writing the RISC-V Dovetail Arch Hooks

> **Confirmed (2026-04-01):** After inspecting `~/work/linux-evl` (tag
> `v6.6.63-evl2-rebase`), the EVL tree has **no RISC-V Dovetail support
> anywhere** — no branches, no tags, no commits touching `arch/riscv/` for
> Dovetail. `HAVE_DOVETAIL` is only selected for `arm64` and `arm`.
> The mailing list option is worth checking, but the most reliable path is
> to write the arch hooks from scratch using ARM64 as a template.

### 9.1 Check EVL Mailing List First (Quick, Low Effort)

Before writing from scratch, spend 10 minutes checking the mailing list:

```
https://lore.kernel.org/xenomai/
https://xenomai.org/pipermail/xenomai/
```

Search: `riscv dovetail` — if a patch series exists, download and save to
`patches/`, then skip to §9.4.

### 9.2 Confirmed State of the EVL Tree

```bash
# Verified on 2026-04-01:
cd ~/work/linux-evl

# No RISC-V Dovetail commits on any branch:
git log --oneline --all -- arch/riscv/ | grep -i "dovetail\|pipeline\|oob"
# Output: (empty — only one unrelated file-rename commit)

# No HAVE_DOVETAIL for RISC-V:
grep -rn "HAVE_DOVETAIL" arch/riscv/
# Output: (empty)

# arch/riscv/include/asm/dovetail.h does NOT exist
# HAVE_DOVETAIL only exists for: arch/arm64, arch/arm
```

### 9.3 Writing the Arch Hooks from Scratch

The patch is in `patches/0002-riscv-dovetail-arch-hooks.patch`. It adds the
minimum set of changes needed to make `CONFIG_DOVETAIL=y` work on RISC-V.

#### Files to create/modify:

| File | Change | Template |
|------|--------|----------|
| `arch/riscv/Kconfig` | Add `select HAVE_IRQ_PIPELINE` + `select HAVE_DOVETAIL` | `arch/arm64/Kconfig` line 218-219 |
| `arch/riscv/include/asm/dovetail.h` | New file: trap macros, FPU hooks | `arch/arm64/include/asm/dovetail.h` |
| `arch/riscv/include/dovetail/thread_info.h` | New file: include asm-generic EVL thread_info | `arch/arm64/include/dovetail/thread_info.h` |
| `arch/riscv/include/asm/thread_info.h` | Add `struct oob_thread_state oob_state` to `struct thread_info` | `arch/arm64/include/asm/thread_info.h` line 48 |
| `arch/riscv/kernel/traps.c` | `handle_riscv_irq`: wrap `handle_arch_irq` with `handle_irq_pipelined` | `arch/arm64/kernel/irq.c` |

#### Key insight from ARM64 reference:

The ARM64 `irq.c` includes `<linux/irq_pipeline.h>` and the `handle_arch_irq`
function pointer is called through the pipeline. For RISC-V, `handle_riscv_irq`
in `arch/riscv/kernel/traps.c` calls `handle_arch_irq(regs)` directly — this
needs to be wrapped with `handle_irq_pipelined()` when `CONFIG_IRQ_PIPELINE=y`.

The patch is already written at `patches/0002-riscv-dovetail-arch-hooks.patch`.

### 9.4 Applying the Patch and Rebuilding

```bash
# On WSL2 host, in the kernel tree
cd ~/work/linux-k1

# Apply the new arch patch (0001 is already applied)
git apply --check patches/0002-riscv-dovetail-arch-hooks.patch
git apply patches/0002-riscv-dovetail-arch-hooks.patch

# Verify the key files now exist
ls arch/riscv/include/asm/dovetail.h          # must exist
grep "HAVE_DOVETAIL" arch/riscv/Kconfig        # must show: select HAVE_DOVETAIL

# Reconfigure — this time CONFIG_DOVETAIL=y will actually be accepted
rm -f .evl-patches-applied   # allow re-apply if needed
bash scripts/build/02-configure.sh

# Verify config
grep "CONFIG_DOVETAIL\|CONFIG_EVL_CORE\|CONFIG_IRQ_PIPELINE" ~/work/build-k1/.config
# Must show: CONFIG_DOVETAIL=y, CONFIG_EVL_CORE=y, CONFIG_IRQ_PIPELINE=y

# Build
bash scripts/build/03-build-kernel.sh

# Make new image
bash scripts/flash/make-full-sdcard-img.sh \
  ~/Downloads/buildroot-k1_rt-sdcard.img \
  ~/work/build-k1 \
  /tmp

# Flash to SD card, reboot Jupiter, then verify via SSH:
ssh root@192.168.1.110 "dmesg | grep -i evl"
# Expected: EVL: core started, ABI 19
```

### 9.5 Expected Build Errors and Fixes

The first build attempt with the arch patch will likely hit compilation errors.
Common ones:

| Error | Cause | Fix |
|-------|-------|-----|
| `undefined reference to 'handle_irq_pipelined'` | `CONFIG_IRQ_PIPELINE=y` not set, or `irq_pipeline.h` not included | Add `#include <linux/irq_pipeline.h>` to `traps.c` |
| `arch/riscv/include/asm/dovetail.h: No such file` | Patch not applied | Re-run `git apply` |
| `struct thread_info has no member oob_state` | `thread_info.h` patch missing | Check patch applied correctly |
| `HAVE_DOVETAIL` not in `.config` | `arch/riscv/Kconfig` patch missing | Verify `select HAVE_DOVETAIL` in Kconfig |
| FPU-related build error | `arch_dovetail_switch_finish` references missing FPU function | Stub out FPU hooks initially (no-op), add real FPU save/restore later |

---

## 10. Build Fixes Applied (2026-04-01) — `patches/0004-riscv-evl-build-fixes.patch`

After applying patches `0001`–`0003`, the kernel build hit 14 distinct errors.
All were fixed and captured in `patches/0004-riscv-evl-build-fixes.patch`.

### 10.1 Summary of Fixes

| # | Error | File(s) Changed | Fix |
|---|-------|-----------------|-----|
| 1 | `evl_wait_channel` incomplete type in `evl_put_thread_wchan` | `include/evl/thread.h` | Add `#include <evl/wait.h>` before the inline function |
| 2 | `EVL_MM_PTSYNC_BIT` undeclared | `include/dovetail/mm_info.h` | Include `asm-generic/evl/mm_info.h` when `CONFIG_EVL` is set |
| 3 | `mmc_host_ops.encrypt_config` missing field | `include/linux/mmc/host.h` | Restore SpacemiT-specific `void (*encrypt_config)(struct mmc_host *, unsigned int)` |
| 4 | `MMC_CAP2_DISABLE_PROBE_SCAN` undeclared | `include/linux/mmc/host.h` | Restore `#define MMC_CAP2_DISABLE_PROBE_SCAN (1 << 29)` |
| 5 | `asm/evl/calibration.h` missing | `arch/riscv/include/asm/evl/calibration.h` | New file: `evl_get_default_clock_gravity()` returns 3000 ns |
| 6 | `asm/evl/fptest.h` missing | `arch/riscv/include/asm/evl/fptest.h`, `arch/riscv/include/uapi/asm/evl/fptest.h` | New files: RISC-V FPU test hooks using `CONFIG_FPU` guard and `fmv.d.x`/`fmv.x.d` |
| 7 | `syscall_get_arg0` undeclared | `arch/riscv/include/asm/syscall.h` | Add `syscall_get_arg0()` returning `regs->orig_a0` |
| 8 | `EVL_POLL_NR_CONNECTORS` / `evl_poll_connector` undefined | `include/dovetail/poll.h` | Include `asm-generic/evl/poll.h` when `CONFIG_EVL` is set |
| 9 | Assembly error from `asm-generic/evl/thread_info.h` | `include/asm-generic/evl/thread_info.h`, `arch/riscv/include/asm/thread_info.h` | Add `#ifndef __ASSEMBLY__` guard; move `dovetail/thread_info.h` include inside `#ifndef __ASSEMBLY__` |
| 10 | `dovetail/thread_info.h` missing full `oob_thread_state` | `include/dovetail/thread_info.h` | Include `asm-generic/evl/thread_info.h` when `CONFIG_EVL` is set |
| 11 | `irq_send_oob_ipi` undefined reference | `arch/riscv/kernel/smp.c` | Add implementation using `__ipi_send_mask(ipi_desc[slot], cpumask)` |
| 12 | `compat_ptr_oob_ioctl` undefined reference | `fs/ioctl.c` | Add `compat_ptr_oob_ioctl()` delegating to `file->f_op->oob_ioctl` |
| 13 | `arch_do_IRQ_pipelined` undefined reference | `arch/riscv/kernel/irq_pipeline.c` (new) | New file: RISC-V arch hook using `irq_enter/exit` + `handle_irq_desc` |
| 14 | `arch_irq_pipeline_init` undefined reference | `arch/riscv/kernel/irq_pipeline.c` (new) | Empty init (no per-arch init needed for RISC-V) |

### 10.2 Key Design Decisions

#### `irq_send_oob_ipi` (RISC-V-specific)

RISC-V uses a virtual IPI descriptor array (`ipi_desc[]`) indexed from
`ipi_virq_base`. OOB IPIs occupy slots `OOB_IPI_OFFSET` through
`OOB_IPI_OFFSET + OOB_NR_IPI - 1`. The implementation:

```c
void irq_send_oob_ipi(unsigned int irq, const struct cpumask *cpumask)
{
    unsigned int slot = irq - ipi_virq_base;
    __ipi_send_mask(ipi_desc[slot], cpumask);
}
```

This uses generic RISC-V IPI infrastructure — **not** a copy of ARM64.

#### `arch_do_IRQ_pipelined` (RISC-V-specific)

Uses generic kernel APIs (`irq_pipeline` per-CPU struct, `irq_enter/exit`,
`handle_irq_desc`, `set_irq_regs`) that are architecture-independent:

```c
void arch_do_IRQ_pipelined(struct irq_desc *desc)
{
    struct pt_regs *regs = raw_cpu_ptr(&irq_pipeline.tick_regs);
    struct pt_regs *old_regs = set_irq_regs(regs);
    irq_enter();
    handle_irq_desc(desc);
    irq_exit();
    set_irq_regs(old_regs);
}
```

#### Dovetail placeholder headers

Many `include/dovetail/` headers are stubs that define empty structs by
default. When `CONFIG_EVL` is set they must include the real EVL struct
definitions from `include/asm-generic/evl/`. The fix pattern is:

```c
#ifdef CONFIG_EVL
#include <asm-generic/evl/X.h>
#else
struct oob_X_state { };
#endif
```

Applied to: `dovetail/mm_info.h`, `dovetail/poll.h`, `dovetail/thread_info.h`.

#### SpacemiT-specific MMC additions

When EVL headers were bulk-copied from the EVL reference tree, SpacemiT-specific
additions in `include/linux/mmc/host.h` were overwritten. These must be
preserved:

- `void (*encrypt_config)(struct mmc_host *host, unsigned int enc_flag)` in
  `struct mmc_host_ops` — used by `drivers/mmc/host/sdhci.c`
- `#define MMC_CAP2_DISABLE_PROBE_SCAN (1 << 29)` — used by SpacemiT SDHCI

### 10.3 Build Result

```
  LD      vmlinux
  OBJCOPY arch/riscv/boot/Image
  Kernel: arch/riscv/boot/Image is ready
```

Image size: **28 MB** at `~/work/build-k1/arch/riscv/boot/Image`.

### 10.4 Next Step: Flash and Verify

```bash
# Build SD card image with new EVL kernel
bash scripts/flash/make-full-sdcard-img.sh \
  ~/Downloads/buildroot-k1_rt-sdcard.img \
  ~/work/build-k1 \
  /tmp

# Flash to SD card (replace /dev/sdX)
sudo dd if=/tmp/evl-sdcard-k1-$(date +%Y%m%d).img of=/dev/sdX bs=4M status=progress

# Boot Jupiter, then verify via SSH:
ssh root@<jupiter-ip> "dmesg | grep -i evl"
# Expected: EVL: core started, ABI 19
ssh root@<jupiter-ip> "evl check"
# Expected: OK
```
