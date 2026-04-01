# Patches — SpacemiT K1 EVL Kernel Port

This directory contains all patches needed to build an EVL-enabled kernel
for the SpacemiT K1 SoC (Milk-V Jupiter board, RISC-V64).

---

## Patch Overview

| # | File | Size | Description |
|---|------|------|-------------|
| 1 | [`0001-evl-dovetail-from-filesystem-diff.patch`](0001-evl-dovetail-from-filesystem-diff.patch) | 647 KB | EVL core + Dovetail infrastructure (filesystem diff from `linux-evl`) |
| 2 | [`0002-riscv-dovetail-arch-hooks.patch`](0002-riscv-dovetail-arch-hooks.patch) | 8.9 KB | RISC-V Dovetail arch hooks (written from scratch — not in upstream EVL) |
| 3 | [`0003-evl-core-infrastructure.patch`](0003-evl-core-infrastructure.patch) | 144 KB | EVL-modified core kernel headers and subsystems |
| 4 | [`0004-riscv-evl-build-fixes.patch`](0004-riscv-evl-build-fixes.patch) | 38 KB | Build error fixes for SpacemiT K1 (14 errors resolved) |

Apply in order: **0001 → 0002 → 0003 → 0004**.

---

## Quick Start

```bash
# 1. Set up environment (clone linux-k1, linux-evl, toolchain)
bash scripts/build/00-setup-env.sh

# 2. Apply all patches
bash scripts/build/01-apply-patches.sh

# 3. Configure kernel
bash scripts/build/02-configure.sh

# 4. Build kernel
bash scripts/build/03-build-kernel.sh
```

The apply script (`01-apply-patches.sh`) automatically applies all `*.patch`
files in this directory in sorted order. It is idempotent — re-running after
a successful apply is a no-op.

---

## Patch Details

### 0001 — EVL Core + Dovetail Infrastructure

**Source:** Filesystem diff between `linux-evl` (tag `v6.6.63-evl2-rebase`,
`source.denx.de`) and the SpacemiT K1 kernel tree (`linux-k1`).

**What it adds:**
- `kernel/evl/` — EVL real-time core (scheduler, clock, heap, mutex, etc.)
- `kernel/dovetail/` — Dovetail IRQ pipeline core
- `include/linux/dovetail.h` — Dovetail public API
- `include/linux/irq_pipeline.h` — IRQ pipeline public API
- `include/evl/` — EVL kernel headers
- `include/uapi/evl/` — EVL userspace ABI headers

**Note:** This patch does **not** include RISC-V arch hooks. Those are in
`0002`. The EVL tree (`v6.6.63-evl2-rebase`) only has Dovetail support for
`arm64` and `arm` — RISC-V support was written from scratch.

---

### 0002 — RISC-V Dovetail Arch Hooks

**Source:** Written from scratch (2026-04-01). Not available in any upstream
EVL branch or mailing list as of this date.

**What it adds/modifies:**

| File | Change |
|------|--------|
| `arch/riscv/Kconfig` | Add `select HAVE_IRQ_PIPELINE` + `select HAVE_DOVETAIL` |
| `arch/riscv/include/asm/dovetail.h` | New: OOB thread state, trap macros, FPU hooks |
| `arch/riscv/include/asm/irq_pipeline.h` | New: RISC-V IRQ pipeline arch header |
| `arch/riscv/include/asm/irqflags.h` | Add `hard_local_irq_*` pipeline variants |
| `arch/riscv/include/asm/mmu_context.h` | Add OOB MM context hooks |
| `arch/riscv/include/asm/thread_info.h` | Add `struct oob_thread_state oob_state` to `thread_info` |
| `arch/riscv/include/dovetail/thread_info.h` | New: include `asm-generic/evl/thread_info.h` |
| `arch/riscv/kernel/traps.c` | Wrap `handle_arch_irq` with `handle_irq_pipelined` |
| `arch/riscv/kernel/smp.c` | Add OOB IPI infrastructure |

**Key design note:** `HAVE_DOVETAIL` must be selected in `arch/riscv/Kconfig`
for `CONFIG_DOVETAIL=y` to be accepted by `make olddefconfig`. Without this,
the EVL config options are silently dropped and the kernel builds without EVL.

---

### 0003 — EVL Core Infrastructure (Modified Kernel Headers)

**Source:** Filesystem diff — EVL-modified versions of standard kernel files.

**What it modifies:**

| Subsystem | Files | Change |
|-----------|-------|--------|
| IRQ flags | `include/linux/irqflags.h`, `include/asm-generic/irqflags.h` | Add `hard_local_irq_*` wrappers for pipeline |
| Preemption | `include/linux/preempt.h` | Add OOB preemption count, `hard_preempt_*` |
| Spinlocks | `include/linux/spinlock*.h` | Pipeline-aware spinlock variants |
| IRQ core | `kernel/irq/chip.c`, `manage.c`, `handle.c`, etc. | Pipeline dispatch, OOB IRQ routing |
| Scheduler | `kernel/sched/core.c`, `idle.c` | OOB context switch hooks |
| Timekeeping | `kernel/time/clockevents.c`, `tick-common.c` | Proxy tick for EVL clock |
| Printk | `kernel/printk/printk.c` | Pipeline-safe printk |
| Entry | `kernel/entry/common.c` | OOB syscall interception |
| MMC | `include/linux/mmc/host.h` | SpacemiT `encrypt_config` + `MMC_CAP2_DISABLE_PROBE_SCAN` |

---

### 0004 — RISC-V EVL Build Fixes

**Source:** `git format-patch` from commit `dea9192fa` in `linux-k1`.

**What it fixes (14 build errors):**

| # | Error | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | `evl_wait_channel` incomplete type | `evl_put_thread_wchan` uses `wchan->lock` but struct was forward-declared only | Add `#include <evl/wait.h>` in `include/evl/thread.h` |
| 2 | `EVL_MM_PTSYNC_BIT` undeclared | `dovetail/mm_info.h` placeholder had empty `oob_mm_state` | Include `asm-generic/evl/mm_info.h` when `CONFIG_EVL` |
| 3 | `mmc_host_ops.encrypt_config` missing | SpacemiT field overwritten by EVL bulk copy | Restore `void (*encrypt_config)(struct mmc_host *, unsigned int)` |
| 4 | `MMC_CAP2_DISABLE_PROBE_SCAN` undeclared | SpacemiT cap overwritten by EVL bulk copy | Restore `#define MMC_CAP2_DISABLE_PROBE_SCAN (1 << 29)` |
| 5 | `asm/evl/calibration.h` missing | No RISC-V version existed | New file: `evl_get_default_clock_gravity()` = 3000 ns |
| 6 | `asm/evl/fptest.h` missing | No RISC-V version existed | New files: FPU test hooks using `fmv.d.x`/`fmv.x.d` (D-extension) |
| 7 | `syscall_get_arg0` undeclared | ARM64 defines it; RISC-V didn't | Add to `arch/riscv/include/asm/syscall.h`, returns `regs->orig_a0` |
| 8 | `EVL_POLL_NR_CONNECTORS` undefined | `dovetail/poll.h` placeholder had empty `oob_poll_wait` | Include `asm-generic/evl/poll.h` when `CONFIG_EVL` |
| 9 | Assembly error from `evl/thread_info.h` | C struct definitions seen by assembler | Add `#ifndef __ASSEMBLY__` guard; move include inside guard in `thread_info.h` |
| 10 | `dovetail/thread_info.h` missing full struct | Placeholder had empty `oob_thread_state` | Include `asm-generic/evl/thread_info.h` when `CONFIG_EVL` |
| 11 | `irq_send_oob_ipi` undefined | No RISC-V implementation | Add to `smp.c`: `__ipi_send_mask(ipi_desc[slot], cpumask)` |
| 12 | `compat_ptr_oob_ioctl` undefined | Not in SpacemiT `fs/ioctl.c` | Add implementation delegating to `file->f_op->oob_ioctl` |
| 13 | `arch_do_IRQ_pipelined` undefined | No RISC-V arch file | New `arch/riscv/kernel/irq_pipeline.c` using `irq_enter/exit` + `handle_irq_desc` |
| 14 | `arch_irq_pipeline_init` undefined | No RISC-V arch file | Empty init in `arch/riscv/kernel/irq_pipeline.c` |

**Files changed (18):**

```
arch/riscv/include/asm/dovetail.h          (staged from 0002, included here)
arch/riscv/include/asm/evl/calibration.h   NEW
arch/riscv/include/asm/evl/fptest.h        NEW
arch/riscv/include/asm/irq_pipeline.h      (staged from 0002, included here)
arch/riscv/include/asm/syscall.h           syscall_get_arg0 added
arch/riscv/include/asm/thread_info.h       dovetail include moved inside #ifndef __ASSEMBLY__
arch/riscv/include/dovetail/thread_info.h  (staged from 0002, included here)
arch/riscv/include/uapi/asm/evl/fptest.h   NEW
arch/riscv/kernel/Makefile                 irq_pipeline.o added
arch/riscv/kernel/irq_pipeline.c           NEW
arch/riscv/kernel/smp.c                    irq_send_oob_ipi added
fs/ioctl.c                                 compat_ptr_oob_ioctl added
include/asm-generic/evl/thread_info.h      #ifndef __ASSEMBLY__ guard added
include/dovetail/mm_info.h                 include real EVL struct when CONFIG_EVL
include/dovetail/poll.h                    include real EVL struct when CONFIG_EVL
include/dovetail/thread_info.h             include real EVL struct when CONFIG_EVL
include/evl/thread.h                       #include <evl/wait.h> added
include/linux/mmc/host.h                   SpacemiT additions restored
```

**Build result after applying all 4 patches:**
```
  Kernel: arch/riscv/boot/Image is ready   (28 MB)
```

---

## Regenerating Patches

To regenerate `0004` after making further changes to `linux-k1`:

```bash
cd ~/work/linux-k1

# Stage your changes
git add <files>

# Commit
git commit -m "riscv: evl: <description>"

# Generate patch
git format-patch -1 HEAD --stdout > ~/projects/spacemit-xenomai/patches/0004-riscv-evl-build-fixes.patch
```

To regenerate `0001`/`0003` (filesystem diff patches):

```bash
bash scripts/patch/gen-patch.sh --yes
```

---

## Applying Patches Manually

If `01-apply-patches.sh` fails, apply manually with 3-way merge:

```bash
cd ~/work/linux-k1

# Check first
git apply --check patches/0004-riscv-evl-build-fixes.patch

# Apply (with 3-way merge fallback)
git apply --3way patches/0004-riscv-evl-build-fixes.patch

# If conflicts remain, resolve them, then:
git add -u
git commit -m "riscv: evl: resolve merge conflicts"
```

---

## Next Steps After Applying

1. **Configure:** `bash scripts/build/02-configure.sh`
2. **Verify config:**
   ```bash
   grep -E "CONFIG_DOVETAIL|CONFIG_EVL_CORE|CONFIG_IRQ_PIPELINE" ~/work/build-k1/.config
   # Must show: CONFIG_DOVETAIL=y, CONFIG_EVL_CORE=y, CONFIG_IRQ_PIPELINE=y
   ```
3. **Build:** `bash scripts/build/03-build-kernel.sh`
4. **Flash:** `bash scripts/flash/make-full-sdcard-img.sh ...`
5. **Verify on Jupiter:**
   ```bash
   ssh root@<jupiter-ip> "dmesg | grep -i evl"
   # Expected: EVL: core started, ABI 19
   ```

See [`docs/porting-notes.md`](../docs/porting-notes.md) for full porting
history and [`docs/testing.md`](../docs/testing.md) for testing procedures.
