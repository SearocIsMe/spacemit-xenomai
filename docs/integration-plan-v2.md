# Xenomai 4 / EVL on Milk-V Jupiter — Integration Plan v2

> **Date:** 2026-05-04  
> **Based on:** Full repository audit — README, all docs, kernel-overlay sources, build/flash scripts, QEMU scripts  
> **Supersedes:** `docs/integration-plan-glm51.md` (which was written before PLIC/BOOTDBG fixes)  
> **Status:** Actionable plan — requires UART feedback from Jupiter to proceed past Phase 2

---

## 1. Project Goal — My Understanding

The objective is to **integrate Xenomai 4 (EVL) into the SpacemiT K1 RISC-V Linux system** running on the **Milk-V Jupiter** development board, enabling the following s-aiotm atomic capabilities on a RISC-V edge node:

| s-aiotm ID | Capability | EVL Mechanism |
|-----------|-----------|---------------|
| 01 | Heterogeneous protocol adaptation | EVL proxy driver + OOB IRQ handler (CAN, RS-485) |
| 03 | Real-time data bus | `evl_xbuf` zero-copy ring buffer + `evl_mutex` |
| 04 | Closed-loop control execution | `evl_thread` 1 kHz periodic + `evl_timer` + `evl_heap` |
| 08 | Task scheduling | EVL `SCHED_QUOTA` + `SCHED_TP` + CPU pinning |

**The concrete success criterion is:** an SD card image that boots on Milk-V Jupiter with `CONFIG_IRQ_PIPELINE=y`, `CONFIG_DOVETAIL=y`, `CONFIG_EVL=y`, reaches userspace, and passes `evl check`.

**The current blocker is:** IRQ-pipeline-enabled kernel images hang at the Bianbu logo on Jupiter, while the vanilla (non-pipelined) kernel boots fine. QEMU `irq-pipeline` boots after the `riscv_v_context_nesting_end()` fix, but Jupiter still hangs.

---

## 2. What Has Been Accomplished

### 2.1 Build Pipeline ✅

- [`scripts/build/00-setup-env.sh`](scripts/build/00-setup-env.sh) clones SpacemiT `linux-6.6` (branch `k1-bl-v2.1.y`) and EVL reference tree
- [`scripts/build/00b-deploy-overlay.sh`](scripts/build/00b-deploy-overlay.sh) deploys `kernel-overlay/` into the kernel tree via rsync
- [`scripts/build/02-configure.sh`](scripts/build/02-configure.sh) merges `spacemit_k1_v2_defconfig` + EVL fragment
- [`scripts/build/03-build-kernel.sh`](scripts/build/03-build-kernel.sh) builds `Image`, `dtbs`, and modules successfully
- **Result:** `Kernel: arch/riscv/boot/Image is ready` ✅ (33 MB EVL kernel)

### 2.2 Kernel Overlay ✅ (build-complete, runtime-unvalidated)

The `kernel-overlay/` directory is complete enough to deploy all EVL/Dovetail sources into the SpacemiT `linux-k1` tree and produce a successful build:

- **Dovetail core:** `kernel/dovetail.c`, `include/linux/dovetail.h`, `include/linux/irq_pipeline.h`, `include/linux/irqstage.h`
- **IRQ pipeline:** `kernel/irq/` modifications, `arch/riscv/kernel/irq_pipeline.c`, `arch/riscv/include/asm/irq_pipeline.h`
- **RISC-V arch hooks:** `arch/riscv/include/asm/dovetail.h`, `arch/riscv/include/asm/irqflags.h`, `arch/riscv/kernel/traps.c`, `arch/riscv/kernel/smp.c`
- **EVL core:** `kernel/evl/` subtree, `include/evl/`, `include/uapi/evl/`
- **Bridge headers:** `arch/riscv/include/dovetail/*.h`, `include/asm-generic/evl/`

### 2.3 Flash Pipeline ✅

- [`scripts/flash/make-baseline-sdcard-img.sh`](scripts/flash/make-baseline-sdcard-img.sh) — safest `kernel-only` image
- [`scripts/flash/make-kernel-modules-sdcard-img.sh`](scripts/flash/make-kernel-modules-sdcard-img.sh) — `kernel-modules` image
- [`scripts/flash/make-full-sdcard-img.sh`](scripts/flash/make-full-sdcard-img.sh) — staged profiles: `kernel-only`, `kernel-modules`, `env-debug`, `boot-debug`, `full-evl`
- The `kernel-only` profile preserves the base image bootflow, initramfs, env, and rootfs — image assembly is no longer the primary suspect

### 2.4 QEMU virt Validation Lane ✅ (partially working)

- [`scripts/build/build-qemu-virt-bisect.sh`](scripts/build/build-qemu-virt-bisect.sh) builds QEMU variants
- [`scripts/qemu/run-riscv64-virt.sh`](scripts/qemu/run-riscv64-virt.sh) runs kernels on QEMU virt
- **QEMU `irq-pipeline` boots successfully** after fixing `riscv_v_context_nesting_end()` (commit `75bef2e`)
- QEMU validation confirmed: `kdevtmpfs` starts, `kworker_u` starts, no `handle_bad_stack`, no `Invalid read at addr 0xFFC`
- **QEMU build gap:** `vanilla-qemu` and `irq-pipeline-qemu` builds fail due to missing overlay coverage for `kernel/sched/core.c` (`irq_pipeline_set_ttwu_window`) and `arch/riscv/kernel/smpboot.c` (`inband_irq_enable`)

### 2.5 Key Bugs Found and Fixed ✅

| # | Bug | Symptom | Fix | Status |
|---|-----|---------|-----|--------|
| 1 | `kernel/dovetail.c` never compiled | `dovetail_call_mayday` undefined | Added `obj-$(CONFIG_DOVETAIL) += dovetail.o` to `kernel/Makefile` | ✅ Fixed |
| 2 | `MMF_DOVETAILED` bit 31 missing | Undeclared in `kernel/dovetail.c` | Added `#define MMF_DOVETAILED 31` | ✅ Fixed |
| 3 | `syscall_get_arg0` missing on RISC-V | Undeclared in `include/linux/dovetail.h` | Added inline returning `regs->orig_a0` | ✅ Fixed |
| 4 | `stall_bits` missing from `task_struct` | Compile error | Added `stall_bits` field under `CONFIG_IRQ_PIPELINE` | ✅ Fixed |
| 5 | `#include <linux/irqstage.h>` missing | Compile error in `kernel/sched/core.c` | Added include | ✅ Fixed |
| 5b | `init_task_stall_bits(p)` in `__sched_fork()` | Boot hang at Bianbu splash | **Reverted** — zero-initialization is correct (INBAND_STALL_BIT=1 would disable IRQs for all new tasks) | ✅ Reverted |
| 6 | `irqflags.h` defined `arch_local_*()` directly | Boot hang — races with OOB SR_IE control | Split: `irqflags.h` → `native_*()` only; `irq_pipeline.h` → `arch_local_*()` via stall-bit | ✅ Fixed |
| 7 | `arch_steal_pipelined_tick()` checked SR_IE | Every tick stolen, jiffies frozen | Fixed to check `SR_PIE` (pre-trap SIE value) | ✅ Fixed |
| 8 | `riscv_v_context_nesting_end()` checked virtual IRQ state | WARN → stack corruption on QEMU | Fixed to check hard IRQ state (commit `75bef2e`) | ✅ Fixed |
| 9 | PLIC `IRQCHIP_PIPELINE_SAFE` missing | WARN for every PLIC IRQ; pipeline may not route external interrupts | Added `IRQCHIP_PIPELINE_SAFE` to `plic_edge_chip` and `plic_chip` | ✅ Fixed |
| 10 | PCIe MSI `IRQCHIP_PIPELINE_SAFE` missing | Same as above for PCIe MSI | Added `IRQCHIP_PIPELINE_SAFE` to `k1x_msi_irq_chip` and `k1x_pcie_msi_bottom_irq_chip` | ✅ Fixed |
| 11 | `evl_debug` early param didn't enable runtime trace | All `EVLDBG` traces were dead at runtime | Now sets both `riscv_evl_early_debug_enabled` and `riscv_evl_runtime_trace_enabled` | ✅ Fixed |
| 12 | BOOTDBG prints were disabled | No visibility into IRQ pipeline flow | Enabled rate-limited BOOTDBG prints in `irq_pipeline.h` and `irq_pipeline.c` | ✅ Fixed |

---

## 3. What Has NOT Been Accomplished — The Current Blocker

### 3.1 Jupiter On-Board Boot Failure ❌

**The central problem:** IRQ-pipeline-enabled kernel images do **not** boot on the Milk-V Jupiter board.

Evidence:

- `vanilla-k1` (no EVL/Dovetail) **boots on Jupiter** ✅
- `irq-pipeline-only` **hangs at Bianbu logo** ❌
- `irq-pipeline-noidle` **hangs at Bianbu logo** ❌
- `irq-pipeline-nosmp` **hangs at Bianbu logo** ❌
- `irq-pipeline-minimal` — **not yet tested on Jupiter** (next step)

**Interpretation:** The boot blocker is **below EVL and below Dovetail** — it is in the RISC-V IRQ pipeline runtime semantics themselves. Disabling SMP and idle did not avoid the hang, so the next focus should be the single-core local IRQ/timer/trap path.

### 3.2 QEMU vs Jupiter Gap

QEMU `irq-pipeline` boots after the `riscv_v_context_nesting_end()` fix, but Jupiter still hangs. This means:

- **Generic RISC-V pipeline semantics** are partially correct (QEMU proves it)
- **SpacemiT K1-specific paths** (PLIC, CLINT, clock, boot flow, vendor drivers) have additional issues not exercised by QEMU virt

### 3.3 Unresolved Technical Items

| Item | Status | Risk | Impact |
|------|--------|------|--------|
| FPU/Vector save-restore for OOB threads | Placeholder only | High | EVL stress validation impossible |
| `switch_oob_mm()` implementation | Minimal (`switch_mm` wrapper) | High | May cause MM corruption under Dovetail |
| `arch_dovetail_switch_*()` hooks | Stubbed (empty) | High | Alternate scheduling untested |
| `arch/riscv/include/asm/evl/fptest.h` | Placeholder | High | FPU corruption under EVL self-tests |
| EVL clock gravity calibration | Default values, not K1-measured | Medium | Latency numbers unvalidated |
| PLIC driver pipeline awareness | `IRQCHIP_PIPELINE_SAFE` added but not runtime-validated on Jupiter | High | May still not support IRQ domain splitting correctly |
| Timer interrupt pipelined delivery | Not validated on Jupiter | Critical | Timer/tick is #1 boot suspect |
| SpacemiT vendor driver interactions | Not audited for pipeline safety | Medium | May cause stalls or deadlocks |
| QEMU virt build completeness | Missing overlay for `smpboot.c`, `sched/core.c` | Medium | Cannot run QEMU validation lane on this host |

---

## 4. Risks and Difficulties

### 4.1 RISC-V EVL Is Not Upstream (Risk: HIGH)

Xenomai 4 has no officially merged RISC-V support. The October 2025 mailing-list patch series (`PATCH dovetail 0/8 riscv: Add Dovetail support`) is the strongest public signal, but it has not been merged. This means:

- No reference implementation to diff against for the exact kernel version (6.6.63)
- No community validation of RISC-V Dovetail runtime behavior
- Our `kernel-overlay/arch/riscv/` files are **locally written**, not cherry-picked from upstream
- **Mitigation:** Align with the public patch series topics (IRQ flags, timer, trap, MM, FPU) and use them as a behavioral reference even without exact code

### 4.2 SpacemiT Kernel Fork Divergence (Risk: HIGH)

The SpacemiT `k1-bl-v2.1.y` branch has significant customizations over vanilla `v6.6.63`:

- Custom PLIC driver modifications
- Custom clock/pinctrl/power domain drivers
- Custom DTS for Jupiter
- Custom `kernel_mode_vector.c` (source of the QEMU `riscv_v_context_nesting_end` bug)

Each of these is a potential interaction point with the Dovetail IRQ pipeline.

- **Mitigation:** Diff each SpacemiT driver against upstream vanilla; identify which ones call `local_irq_disable()/enable()` and whether they expect hardware masking

### 4.3 PLIC Pipeline Awareness (Risk: HIGH)

The SpacemiT K1 uses a PLIC-compatible interrupt controller. Dovetail requires the PLIC driver to support **IRQ domain splitting** — some IRQ lines claimed by EVL (OOB domain), others by Linux (in-band domain). The `IRQCHIP_PIPELINE_SAFE` flag was added but:

- It only tells the core IRQ code that the chip's handlers are safe to call from the pipeline path
- It does **not** automatically add OOB `irq_chip` ops (`irq_enable_oob`, `irq_disable_oob`, etc.)
- The SpacemiT PLIC driver may have custom `irq_chip` callbacks that bypass the pipeline

- **Mitigation:** Full PLIC driver audit against the EVL reference tree's PLIC driver (if one exists); add OOB-capable `irq_chip` ops if needed

### 4.4 Timer Interrupt Path (Risk: CRITICAL)

The RISC-V timer (`mtime`/`mtimecmp` via CLINT) is used by both Linux (jiffies) and EVL (OOB timers). The pipelined timer path must:

1. Deliver timer IRQ to OOB stage first
2. Forward to in-band Linux only if stall-bit is clear
3. Correctly handle `arch_steal_pipelined_tick()` (already fixed for SR_PIE)

If the SpacemiT CLINT or timer driver deviates from the generic RISC-V model, this path may break.

- **Mitigation:** Audit `drivers/clocksource/timer-riscv.c` in the SpacemiT tree; verify `tick_proxy` registration; add early timer debug prints

### 4.5 SMP/IPI Under Pipeline (Risk: MEDIUM-HIGH)

The K1 has 8 cores. OOB IPI delivery (`irq_send_oob_ipi`) is implemented in [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c) but has never been validated on hardware. SMP pipeline issues could cause:

- IPI storms
- Cross-CPU stall corruption
- Deadlocks in scheduler hand-off

- **Mitigation:** Start with `irq-pipeline-minimal` (SMP disabled) to eliminate this variable; only enable SMP after single-core pipeline is proven

### 4.6 Vendor Driver Pipeline Safety (Risk: MEDIUM)

SpacemiT vendor drivers (clock, pinctrl, MMC, display, GPU) may call `local_irq_disable()`/`local_irq_enable()` expecting hardware masking. Under `CONFIG_IRQ_PIPELINE`, these become stall-bit operations that do **not** actually mask hardware IRQs. This can cause:

- Drivers assuming IRQs are truly disabled when they are not
- Race conditions in device register access
- MMC driver failing to mount rootfs (if SD controller IRQ doesn't flow through pipeline)

- **Mitigation:** `irq-pipeline-minimal` disables most vendor drivers; incremental re-enablement will identify which specific driver breaks

---

## 5. Feasible Step-by-Step Integration Plan

The plan follows the **official Dovetail porting order** and the **existing staged-integration-plan.md philosophy**: prove each layer before climbing to the next.

```
Phase 0: Gold baseline           ✅ DONE (vanilla-k1 boots)
Phase 1: Local vanilla kernel    ✅ DONE (vanilla-k1 boots on Jupiter)
Phase 2: IRQ pipeline on Jupiter ❌ CURRENT BLOCKER
Phase 3: PLIC + Timer audit      ⬜ Depends on Phase 2 UART data
Phase 4: Dovetail w/o EVL        ⬜ Depends on Phase 2 exit
Phase 5: EVL core minimal        ⬜ Depends on Phase 4
Phase 6: EVL userspace           ⬜ Depends on Phase 5
Phase 7: s-aiotm integration     ⬜ Depends on Phase 6
```

### Phase 0: Gold Standard Baseline ✅ (DONE)

**Goal:** Establish an immutable reference point.

**Status:** `vanilla-k1` boots on Jupiter. The official Bianbu base image is confirmed working.

**Required evidence (if not already saved):**
- Full UART log from official Bianbu boot
- `extlinux.conf`, boot partition listing, rootfs UUID
- `uname -a`, `/proc/cmdline`

---

### Phase 1: Locally Built Vanilla Kernel ✅ (DONE)

**Goal:** Prove that a locally built non-EVL kernel from the SpacemiT tree boots when injected into the base image.

**Status:** `vanilla-k1` **already boots on Jupiter** ✅

This confirms:
- The build pipeline produces a valid kernel
- The flash pipeline creates a bootable SD card
- The SpacemiT kernel source is functional when built locally
- Image replacement, DTB placement, and module ABI are not fundamental problems

---

### Phase 2: IRQ Pipeline on Jupiter ← **CURRENT PRIORITY**

**Goal:** Find the first bootable IRQ-pipeline slice on Jupiter, or isolate the exact failure point with UART evidence.

**Why this is the most important phase:** Every subsequent phase depends on proving that the IRQ pipeline can work on K1 hardware. Without this, Dovetail, EVL, and all s-aiotm capabilities are blocked.

#### Step 2a: Test `irq-pipeline-minimal` on Jupiter

This is the most constrained variant (no SMP, no idle, no PM, no FPU, no Vector). If this hangs, the blocker is in the single-core local IRQ/timer/trap path.

```bash
bash scripts/build/00b-deploy-overlay.sh
JOBS=$(nproc) MODULE_JOBS=1 bash scripts/build/build-kernel-bisect.sh irq-pipeline-minimal
bash scripts/flash/make-baseline-sdcard-img.sh <base_image>.img .build/build-k1-irq-pipeline-minimal .build/images
```

Flash to SD, boot on Jupiter, **capture full UART log**.

**Key markers to look for in UART output:**

1. `IRQ pipeline: arch_irq_pipeline_init() called on CPU0` — confirms pipeline init ran
2. `EVLDBG arch_handle_irq_pipelined entry` — first IRQ through the pipeline
3. `BOOTDBG arch_handle_irq_pipelined before_dispatch cause=...` — IRQ cause numbers
4. `BOOTDBG arch_do_IRQ_pipelined enter irq=20` — timer IRQ replay working
5. `riscv-timer: BOOTDBG riscv_timer_starting_cpu` — timer brought up
6. Any WARN/panic/oops — copy the full stack trace

#### Step 2b: Analyze UART output — Decision Tree

| UART Observation | Interpretation | Next Step |
|-----------------|----------------|-----------|
| Kernel banner appears, then hang | Pipeline init OK, later path broken | Check timer/tick/replay; check which initcall hangs |
| No kernel banner, reset to OpenSBI | Very early pipeline failure | Check trap entry, early IRQ dispatch |
| `arch_irq_pipeline_init()` printed but no BOOTDBG | Pipeline init ran but no IRQs delivered | Check PLIC dispatch, check if `handle_arch_irq` is NULL |
| BOOTDBG shows IRQs flowing but jiffies frozen | Timer IRQs not reaching in-band | Check `arch_steal_pipelined_tick()`, check stall-bit state |
| BOOTDBG shows cause=5 (timer) repeatedly | Timer storm / replay loop | Check `arch_do_IRQ_pipelined()` hard_local_irq_save/restore |
| Reaches userspace | Minimal pipeline works! | Promote to `irq-pipeline-nosmp`, then `irq-pipeline-only` |
| No UART output at all after OpenSBI | Pipeline breaks before console init | Need SBI-level early debug or GDB on Jupiter |

#### Step 2c: If minimal hangs — targeted debug

Based on the UART evidence, apply targeted fixes:

**If timer IRQs are not delivered:**
- Check if `riscv_intc_dispatch_irq()` returns 0 for cause=5
- Check if `handle_arch_irq` is set before the first timer IRQ
- Verify the RISC-V INTC driver has `IRQCHIP_PIPELINE_SAFE`

**If timer IRQs are delivered but jiffies don't advance:**
- Add printk in `arch_steal_pipelined_tick()` to see if ticks are being stolen
- Check if `inband_irqs_disabled()` returns the wrong value in the timer path
- Verify stall-bit initialization: `stall_bits` should be 0 (IRQs enabled) for init task

**If PLIC external IRQs are not delivered:**
- Check if `plic_irq_enable()` goes through pipeline-aware path
- Verify `IRQCHIP_PIPELINE_SAFE` is actually present in the running kernel (check `/proc/kallsyms` or build log)
- Check if SpacemiT PLIC driver has custom callbacks that bypass `irq_chip` ops

**If the hang is after pipeline init but before timer:**
- Check if an early initcall calls `local_irq_disable()` and never re-enables
- Check if the stall-bit state is coherent across context switches
- Add `dump_stack()` in `arch_local_irq_disable()` rate-limited to first 10 calls

#### Step 2d: Incremental re-enablement (once minimal boots)

If `irq-pipeline-minimal` boots, re-enable features one at a time:

1. `irq-pipeline-nosmp` — add SMP back
2. `irq-pipeline-noidle` — add idle back
3. `irq-pipeline-only` — full IRQ pipeline, no Dovetail

**Exit criteria:**
- At least one IRQ-pipeline variant reaches userspace on Jupiter, OR
- UART log pinpoints the exact failure point

---

### Phase 3: PLIC + Timer Pipeline Audit (2–3 days)

**Goal:** Ensure the SpacemiT PLIC driver and timer path correctly interact with the Dovetail IRQ pipeline.

**Prerequisite:** Phase 2 has produced UART evidence (even if it's a hang log).

**Why this phase matters:** QEMU virt uses a simple HTIF/INTC model. The SpacemiT K1 has a custom PLIC driver. If IRQ pipeline works on QEMU but not Jupiter, the PLIC driver and timer path are prime suspects.

#### Step 3a: PLIC driver diff

```bash
diff .build/linux-k1/drivers/irqchip/irq-sifive-plic.c \
     kernel-overlay/drivers/irqchip/irq-sifive-plic.c
```

Check for:
- Does the SpacemiT PLIC driver have custom `irq_chip` callbacks?
- Do those callbacks go through `irq_chip_*_parent()` or direct register writes?
- Is `IRQCHIP_PIPELINE_SAFE` present in the **deployed** kernel (not just the overlay)?
- Does the PLIC driver support IRQ domain splitting for OOB?

#### Step 3b: Timer path audit

Audit `drivers/clocksource/timer-riscv.c` in the SpacemiT tree for:
- Does it use `clockevents_config_and_register()` or a pipeline-aware variant?
- Does the timer handler call `irq_pipeline_enter()` / `irq_pipeline_exit()`?
- Is `tick_proxy` enabled for the RISC-V clockevent device?
- Does SpacemiT have a custom CLINT driver that deviates from upstream?

#### Step 3c: Vendor driver audit

Check which SpacemiT drivers call `local_irq_disable()`/`local_irq_enable()`:
```bash
grep -rn "local_irq_disable\|local_irq_enable\|spin_lock_irq\|spin_unlock_irq" \
  .build/linux-k1/drivers/spacemit/ 2>/dev/null | head -50
```

These calls become stall-bit operations under `CONFIG_IRQ_PIPELINE`. If a driver assumes hardware masking, it may race with OOB IRQs.

**Exit criteria:**
- PLIC driver diff documented
- Timer path documented
- Any required pipeline modifications identified and implemented
- QEMU `irq-pipeline` still boots after changes

---

### Phase 4: Dovetail Without EVL (2–3 days)

**Goal:** Prove that alternate scheduling plumbing does not break basic boot.

**Prerequisite:** At least one IRQ-pipeline variant boots on Jupiter (Phase 2 exit).

**Test order:**
1. `dovetail-only`
2. `dovetail-noidle`
3. `dovetail-nosmp`
4. `evl-off`

**Focus files:**
- [`kernel-overlay/arch/riscv/include/asm/dovetail.h`](kernel-overlay/arch/riscv/include/asm/dovetail.h) — currently has stubbed `arch_dovetail_switch_*()` hooks
- [`kernel-overlay/arch/riscv/include/asm/mmu_context.h`](kernel-overlay/arch/riscv/include/asm/mmu_context.h) — `switch_oob_mm()` is minimal
- [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c) — trap mediation under Dovetail
- [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c) — OOB IPI under Dovetail

**Key risk:** The stubbed `arch_dovetail_switch_*()` hooks may be insufficient for Dovetail's scheduler hand-off. If Dovetail expects architecture-specific context save/restore that we haven't implemented, this will deadlock.

**Exit criteria:**
- `dovetail-only` or one reduced variant boots on Jupiter
- No silent deadlock from timer/IPI/trap routing under Dovetail

---

### Phase 5: EVL Core Minimal Bring-up (2–3 days)

**Goal:** Add EVL on top of a booting Dovetail kernel.

**Prerequisite:** Dovetail boots on Jupiter (Phase 4 exit).

**Start with a reduced EVL config:**
- `CONFIG_EVL=y`
- No optional EVL proxy/xbuf/poll/latmon extras at first
- Keep debug enabled
- Do not enable `full-evl` image profile yet

**Board-side checks:**
```bash
dmesg | grep -i "evl\|dovetail\|irq pipeline"
zcat /proc/config.gz | grep -E "CONFIG_DOVETAIL|CONFIG_EVL|CONFIG_IRQ_PIPELINE"
ls /sys/devices/virtual/evl/
cat /proc/evl/version 2>/dev/null
```

**Exit criteria:**
- Board boots with `CONFIG_EVL=y`
- EVL announces itself in boot log
- EVL interfaces exist in sysfs or procfs

---

### Phase 6: EVL Userspace and Functional Validation (3–5 days)

**Goal:** Validate that the kernel port is usable, not merely bootable.

**Prerequisite:** EVL kernel boots on Jupiter (Phase 5 exit).

**Actions:**

1. **Build and deploy `libevl` for RISC-V:**
   ```bash
   bash scripts/build/04-build-sdk.sh
   ```

2. **Run `evl check` on Jupiter**

3. **Run `latmus` latency test:**
   ```bash
   evl test latmus -t irq
   ```

4. **Replace FPU/Vector placeholders:**
   - Implement proper FPU save/restore in [`kernel-overlay/arch/riscv/include/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/asm/evl/fptest.h)
   - Implement userspace FPU test ABI in [`kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h)
   - **Reference:** The October 2025 upstream RISC-V patch series covers FPU/vector handling; align with that design

5. **Calibrate clock gravity for K1**

6. **Implement `arch_dovetail_switch_*()` hooks** — currently stubbed; needed for real OOB scheduling

7. **Rework `switch_oob_mm()`** — currently just calls `switch_mm()`; needs Dovetail-aware implementation

**Exit criteria:**
- `evl check` passes
- No trap/FPU corruption under EVL self-tests
- Bounded IRQ latency on Jupiter (< 50 µs worst-case target)

---

### Phase 7: s-aiotm Integration (ongoing)

**Goal:** Enable the four s-aiotm capabilities on the Jupiter + EVL platform.

This is the long-term integration work that depends on all previous phases succeeding. It involves:
- EVL proxy drivers for CAN/RS-485 (s-aiotm 01)
- `evl_xbuf` + `evl_mutex` for real-time data bus (s-aiotm 03)
- `evl_thread` periodic control loops (s-aiotm 04)
- `SCHED_QUOTA` + `SCHED_TP` + CPU pinning (s-aiotm 08)

---

## 6. QEMU Validation Lane — Parallel Track

The QEMU virt lane is a **mandatory architecture smoke-test**, not optional. It separates generic RISC-V port issues from K1-specific boot issues.

### Current QEMU Status

- ✅ QEMU `irq-pipeline` boots after commit `75bef2e`
- ❌ QEMU builds fail on this host due to missing overlay coverage for `smpboot.c` and `sched/core.c`

### QEMU Build Fix Required

Before the QEMU lane can be used on this host, the following overlay gaps must be fixed:

1. [`kernel-overlay/kernel/sched/core.c`](kernel-overlay/kernel/sched/core.c) — missing `irq_pipeline_set_twwu_window()` declaration/definition
2. [`kernel-overlay/arch/riscv/kernel/smpboot.c`](kernel-overlay/arch/riscv/kernel/smpboot.c) — missing `inband_irq_enable()` visibility

These are build-time issues, not runtime issues. Fix them to unlock the QEMU lane for local validation.

### QEMU Validation Order

Once builds work:

1. `vanilla-qemu` — self-check the QEMU lane
2. `irq-pipeline-qemu` — already proven to boot
3. `dovetail-qemu` — validate Dovetail on generic RISC-V
4. `full-evl-qemu` — validate full EVL stack on generic RISC-V

**Interpretation rule:**
- If QEMU fails → fix generic RISC-V pipeline semantics before spending more Jupiter cycles
- If QEMU works and Jupiter fails → prioritize SpacemiT-specific timer/interrupt/boot interactions

---

## 7. Summary: Current Position and Next Move

```
                    COMPLETED                     REMAINING
                    ─────────                     ─────────
Phase 0: Gold baseline     ✅  ──→  
Phase 1: Vanilla kernel    ✅  ──→  
Phase 2: IRQ pipeline      ❌  ←── YOU ARE HERE
Phase 3: PLIC + Timer      ⬜  ──→  
Phase 4: Dovetail w/o EVL  ⬜  ──→  
Phase 5: EVL core          ⬜  ──→  
Phase 6: EVL userspace     ⬜  ──→  
Phase 7: s-aiotm           ⬜  ──→  Final goal
```

**The single most important next action is:**

> **Build `irq-pipeline-minimal`, flash it to Jupiter, and capture the full UART log.**

This is the narrowest possible test that can tell us whether the IRQ pipeline can work at all on the K1 hardware. The result determines everything that follows:

- If it boots → promote upward through `irq-pipeline-nosmp` → `irq-pipeline-only` → `dovetail-only` → `full-evl`
- If it hangs → the UART log will reveal whether the blocker is in trap entry, timer delivery, PLIC dispatch, or early pipeline state — and we fix that specific path before moving on

---

## 8. How to Use UART Feedback Effectively

When you flash an image and boot on Jupiter, please capture and share:

1. **Full UART log** from power-on (OpenSBI) through to hang or login
2. **Which variant** was tested (e.g., `irq-pipeline-minimal`)
3. **Which image profile** was used (e.g., `kernel-only` or `kernel-modules`)
4. **Any on-screen behavior** (HDMI: Bianbu logo? Black screen? Login prompt?)

With the UART log, I can:
- Identify whether the kernel reached `start_kernel()`
- Check if `irq_pipeline_init()` ran
- Determine if timer interrupts are advancing `jiffies`
- Spot any panic, oops, or WARN messages
- Trace the exact point where execution stopped

---

## 9. Key Files to Watch (Class C — Highest Risk)

These are the files most likely causing the Jupiter boot hang under `IRQ_PIPELINE`:

| File | What It Controls | Why Risky |
|------|-----------------|-----------|
| [`kernel-overlay/arch/riscv/include/asm/irqflags.h`](kernel-overlay/arch/riscv/include/asm/irqflags.h) | `native_*()` hardware ops, includes `irq_pipeline.h` | If `arch_local_*()` bypasses stall-bit, OOB stage races with in-band |
| [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h) | `arch_local_*()` via stall-bit, `arch_steal_pipelined_tick()` | SR_PIE fix is critical; any mistake here steals all ticks or none |
| [`kernel-overlay/arch/riscv/kernel/irq_pipeline.c`](kernel-overlay/arch/riscv/kernel/irq_pipeline.c) | `arch_do_IRQ_pipelined()`, `irq_cpuidle_control()` | Hard IRQ save/restore around replay; cpuidle blocking |
| [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c) | IRQ dispatch routing, syscall context fix | Routes IRQs through pipeline; `riscv_syscall_irq_context_fix()` is aggressive |
| [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c) | OOB IPI, `ipi_irq_base` | SMP IPI under pipeline untested on hardware |
| [`kernel-overlay/arch/riscv/include/asm/mmu_context.h`](kernel-overlay/arch/riscv/include/asm/mmu_context.h) | `switch_oob_mm()` | Minimal implementation; may not be Dovetail-correct |

---

## 10. Comparison: QEMU vs Jupiter — Why QEMU Boots But Jupiter Doesn't

| Factor | QEMU virt | SpacemiT K1 (Jupiter) |
|--------|-----------|----------------------|
| Interrupt controller | Simple HTIF/INTC | Custom PLIC with SpacemiT extensions |
| Timer | Generic `riscv_timer` | Same, but CLINT may have vendor tweaks |
| SMP | Configurable (default 1–4) | 8-core X60 |
| Boot flow | OpenSBI → direct kernel load | OpenSBI → U-Boot SPL → extlinux → kernel |
| Drivers | Minimal virtio | Full SpacemiT driver suite (clock, pinctrl, MMC, display) |
| `kernel_mode_vector.c` | Present | Present (bug already fixed) |
| FPU/Vector | Basic emulation | Real X60 with V-extension |

The most likely Jupiter-specific blockers are:
1. **PLIC not fully pipeline-aware** — `IRQCHIP_PIPELINE_SAFE` is added but OOB `irq_chip` ops may be missing
2. **SpacemiT clock/power domain drivers** — may call `local_irq_disable()` expecting hardware masking, but get stall-bit virtualization instead
3. **MMC driver** — if the SD card controller IRQ doesn't flow through the pipeline, the rootfs can't be mounted
4. **Display/GPU driver** — may stall the pipeline during framebuffer init

---

## 11. Design Principles for This Port

1. **First prove boot, then prove real-time semantics** — A bootable image with a locally built non-EVL kernel is more valuable than an EVL-enabled image that hangs at the splash screen.

2. **Follow the official Dovetail porting order** — IRQ pipeline → alternate scheduling → EVL core → EVL library. Skipping steps creates untraceable failures.

3. **Keep bootflow changes minimal until the kernel itself is trusted** — Prefer `kernel-only` and `kernel-modules` profiles before `env-debug`, `boot-debug`, or `full-evl`.

4. **Do not trust local RISC-V stubs as final design** — Anything touching IRQ masking, trap handling, MM context switching, OOB scheduler hand-off, or FPU/Vector handling must be justified against upstream or public mailing-list work, not only against build success.

5. **Treat QEMU `virt` as a mandatory architecture smoke-test lane** — Not optional. It separates generic RISC-V port issues from K1-specific boot issues.

6. **Do not claim RISC-V EVL completion while FPU/Vector placeholders remain** — [`kernel-overlay/arch/riscv/include/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/asm/evl/fptest.h) and [`kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h) must be replaced with real implementations before stress validation is meaningful.

---

## 12. Immediate Action Checklist

- [ ] Build `irq-pipeline-minimal` and flash to Jupiter
- [ ] Capture full UART log from Jupiter boot
- [ ] Analyze UART log against the decision tree in Step 2b
- [ ] Fix QEMU build gaps (`smpboot.c`, `sched/core.c`) to unlock local QEMU validation
- [ ] Run `vanilla-qemu` self-check on this host
- [ ] Run `irq-pipeline-qemu` on this host
- [ ] Diff SpacemiT PLIC driver against upstream
- [ ] Audit SpacemiT timer driver for pipeline awareness
