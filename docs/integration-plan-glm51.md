# Xenomai 4 / EVL on Milk-V Jupiter — Integration Plan (GLM-5.1 Assessment)

> **Date:** 2026-04-29  
> **Author:** GLM-5.1 code analysis  
> **Status:** Planning document — requires human validation before execution

---

## 1. Project Goal — My Understanding

The objective is to **integrate Xenomai 4 (EVL) into the SpacemiT K1 RISC-V Linux system** running on the **Milk-V Jupiter** development board, so that the following s-aiotm atomic capabilities become available on a RISC-V edge node:

| s-aiotm ID | Capability | EVL Mechanism |
|-----------|-----------|---------------|
| 01 | Heterogeneous protocol adaptation | EVL proxy driver + OOB IRQ handler (CAN, RS-485) |
| 03 | Real-time data bus | `evl_xbuf` zero-copy ring buffer + `evl_mutex` |
| 04 | Closed-loop control execution | `evl_thread` 1 kHz periodic + `evl_timer` + `evl_heap` |
| 08 | Task scheduling | EVL `SCHED_QUOTA` + `SCHED_TP` + CPU pinning |

**The concrete success criterion is:** an SD card image that boots on Milk-V Jupiter with `CONFIG_IRQ_PIPELINE=y`, `CONFIG_DOVETAIL=y`, `CONFIG_EVL=y`, reaches userspace, and passes `evl check`.

---

## 2. What Has Been Accomished

### 2.1 Build Pipeline ✅

- [`scripts/build/00-setup-env.sh`](scripts/build/00-setup-env.sh) clones SpacemiT `linux-6.6` (branch `k1-bl-v2.1.y`) and EVL reference tree
- [`scripts/build/00b-deploy-overlay.sh`](scripts/build/00b-deploy-overlay.sh) deploys `kernel-overlay/` into the kernel tree via rsync
- [`scripts/build/02-configure.sh`](scripts/build/02-configure.sh) merges `spacemit_k1_v2_defconfig` + EVL fragment
- [`scripts/build/03-build-kernel.sh`](scripts/build/03-build-kernel.sh) builds `Image`, `dtbs`, and modules successfully
- **Result:** `Kernel: arch/riscv/boot/Image is ready` ✅ (33 MB EVL kernel)

### 2.2 Kernel Overlay ✅

The `kernel-overlay/` directory is complete enough to deploy all EVL/Dovetail sources into the SpacemiT `linux-k1` tree:

- **Dovetail core:** `kernel/dovetail.c`, `include/linux/dovetail.h`, `include/linux/irq_pipeline.h`, `include/linux/irqstage.h`
- **IRQ pipeline:** `kernel/irq/` modifications, `arch/riscv/kernel/irq_pipeline.c`, `arch/riscv/include/asm/irq_pipeline.h`
- **RISC-V arch hooks:** `arch/riscv/include/asm/dovetail.h`, `arch/riscv/include/asm/irqflags.h`, `arch/riscv/kernel/traps.c`, `arch/riscv/kernel/smp.c`
- **EVL core:** `kernel/evl/` subtree, `include/evl/`, `include/uapi/evl/`
- **Bridge headers:** `arch/riscv/include/dovetail/*.h`, `include/asm-generic/evl/`

### 2.3 Flash Pipeline ✅

- [`scripts/flash/make-baseline-sdcard-img.sh`](scripts/flash/make-baseline-sdcard-img.sh) — safest `kernel-only` image
- [`scripts/flash/make-kernel-modules-sdcard-img.sh`](scripts/flash/make-kernel-modules-sdcard-img.sh) — `kernel-modules` image
- [`scripts/flash/make-full-sdcard-img.sh`](scripts/flash/make-full-sdcard-img.sh) — staged profiles: `kernel-only`, `kernel-modules`, `env-debug`, `boot-debug`, `full-evl`

### 2.4 QEMU virt Validation Lane ✅ (partially)

- [`scripts/build/build-qemu-virt-bisect.sh`](scripts/build/build-qemu-virt-bisect.sh) builds QEMU variants
- [`scripts/qemu/run-riscv64-virt.sh`](scripts/qemu/run-riscv64-virt.sh) runs kernels on QEMU virt
- **QEMU `irq-pipeline` boots successfully** after fixing `riscv_v_context_nesting_end()` (commit `75bef2e`)
- QEMU validation confirmed: `kdevtmpfs` starts, `kworker_u` starts, no `handle_bad_stack`, no `Invalid read at addr 0xFFC`

### 2.5 Key Bugs Found and Fixed ✅

| Bug | Symptom | Fix |
|-----|---------|-----|
| `kernel/dovetail.c` never compiled | `dovetail_call_mayday` undefined | Added `obj-$(CONFIG_DOVETAIL) += dovetail.o` to `kernel/Makefile` |
| `MMF_DOVETAILED` bit 31 missing | Undeclared in `kernel/dovetail.c` | Added `#define MMF_DOVETAILED 31` |
| `syscall_get_arg0` missing on RISC-V | Undeclared in `include/linux/dovetail.h` | Added inline returning `regs->orig_a0` |
| `stall_bits` missing from `task_struct` | Compile error | Added `stall_bits` field under `CONFIG_IRQ_PIPELINE` |
| `init_task_stall_bits(p)` in `__sched_fork()` | Boot hang at Bianbu splash | **Reverted** — zero-initialization is correct |
| `irqflags.h` defined `arch_local_*()` directly | Boot hang — races with OOB SR_IE control | Split: `irqflags.h` → `native_*()` only; `irq_pipeline.h` → `arch_local_*()` via stall-bit |
| `arch_steal_pipelined_tick()` checked SR_IE | Every tick stolen, jiffies frozen | Fixed to check `SR_PIE` (pre-trap SIE value) |
| `riscv_v_context_nesting_end()` checked virtual IRQ state | WARN → stack corruption on QEMU | Fixed to check hard IRQ state (commit `75bef2e`) |

---

## 3. What Has NOT Been Accomplished — The Current Blocker

### 3.1 Jupiter On-Board Boot Failure ❌

**The central problem:** EVL-enabled kernel images do **not** boot on the Milk-V Jupiter board.

Evidence from [`docs/staged-integration-plan.md`](docs/staged-integration-plan.md:155):

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

| Item | Status | Risk |
|------|--------|------|
| FPU/Vector save-restore for OOB threads | Placeholder only | High — EVL stress validation impossible |
| `switch_oob_mm()` implementation | Minimal (`switch_mm` wrapper) | High — may cause MM corruption under Dovetail |
| `arch_dovetail_switch_*()` hooks | Stubbed (empty) | High — alternate scheduling untested |
| `arch/riscv/include/asm/evl/fptest.h` | Placeholder | High — FPU corruption under EVL self-tests |
| EVL clock gravity calibration | Default values, not K1-measured | Medium — latency numbers unvalidated |
| PLIC driver pipeline awareness | Not audited | High — may not support IRQ domain splitting |
| Timer interrupt pipelined delivery | Not validated on Jupiter | Critical — timer/tick is #1 boot suspect |
| SpacemiT vendor driver interactions | Not audited for pipeline safety | Medium — may cause stalls or deadlocks |

---

## 4. Risks and Difficulties

### 4.1 RISC-V EVL Is Not Upstream

Xenomai 4 has no officially announced RISC-V support. The October 2025 mailing-list patch series (`PATCH dovetail 0/8 riscv: Add Dovetail support`) is the strongest public signal, but it has not been merged. This means:

- No reference implementation to diff against for the exact kernel version (6.6.63)
- No community validation of RISC-V Dovetail runtime behavior
- Our `kernel-overlay/arch/riscv/` files are **locally written**, not cherry-picked from upstream

### 4.2 SpacemiT Kernel Fork Divergence

The SpacemiT `k1-bl-v2.1.y` branch has significant customizations over vanilla `v6.6.63`:

- Custom PLIC driver modifications
- Custom clock/pinctrl/power domain drivers
- Custom DTS for Jupiter
- Custom `kernel_mode_vector.c` (source of the QEMU `riscv_v_context_nesting_end` bug)

Each of these is a potential interaction point with the Dovetail IRQ pipeline.

### 4.3 PLIC Pipeline Awareness

The SpacemiT K1 uses a PLIC-compatible interrupt controller. Dovetail requires the PLIC driver to support **IRQ domain splitting** — some IRQ lines claimed by EVL (OOB domain), others by Linux (in-band domain). The current overlay does **not** modify [`kernel-overlay/drivers/irqchip/irq-sifive-plic.c`](kernel-overlay/drivers/irqchip/irq-sifive-plic.c) for pipeline awareness, which may be a boot blocker.

### 4.4 Timer Interrupt Path

The RISC-V timer (`mtime`/`mtimecmp` via CLINT) is used by both Linux (jiffies) and EVL (OOB timers). The pipelined timer path must:

1. Deliver timer IRQ to OOB stage first
2. Forward to in-band Linux only if stall-bit is clear
3. Correctly handle `arch_steal_pipelined_tick()` (already fixed for SR_PIE)

If the SpacemiT CLINT or timer driver deviates from the generic RISC-V model, this path may break.

### 4.5 SMP/IPI Under Pipeline

The K1 has 8 cores. OOB IPI delivery (`irq_send_oob_ipi`) is implemented in [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c) but has never been validated on hardware. SMP pipeline issues could cause:

- IPI storms
- Cross-CPU stall corruption
- Deadlocks in scheduler hand-off

---

## 5. Feasible Step-by-Step Integration Plan

The plan follows the **official Dovetail porting order** and the **existing staged-integration-plan.md** philosophy: prove each layer before climbing to the next.

### Phase 0: Gold Standard Baseline (1 day)

**Goal:** Establish an immutable reference point.

**Actions:**
1. Flash the **untouched official Bianbu** SD image on Jupiter
2. Record full UART log from power-on to login prompt
3. Save: `extlinux.conf`, boot partition listing, rootfs UUID, `uname -a`, `/proc/cmdline`
4. Verify serial console works reliably at 115200 8N1

**Exit criteria:**
- Board reaches shell/login reliably
- UART log saved as gold standard reference

**Status:** Likely already done (vanilla-k1 boots). Confirm and document.

---

### Phase 1: Locally Built Vanilla Kernel (1 day)

**Goal:** Prove that a locally built non-EVL kernel from the SpacemiT tree boots when injected into the base image.

**Actions:**
```bash
bash scripts/build/00b-deploy-overlay.sh
JOBS=$(nproc) MODULE_JOBS=1 bash scripts/build/build-kernel-bisect.sh vanilla-k1
bash scripts/flash/make-baseline-sdcard-img.sh <base_image>.img .build/build-k1-vanilla .build/images
```

**Exit criteria:**
- `vanilla-k1 + kernel-only` boots on Jupiter
- If not, try `kernel-modules` profile

**Status:** Per docs, `vanilla-k1` **already boots on Jupiter** ✅

---

### Phase 2: IRQ Pipeline Minimal on Jupiter (2–3 days) ← **CURRENT PRIORITY**

**Goal:** Find the first bootable IRQ-pipeline slice on Jupiter, or isolate the exact failure point with UART evidence.

**Actions:**

#### Step 2a: Test `irq-pipeline-minimal` on Jupiter

This is the most constrained variant (no SMP, no idle, no PM, no FPU, no Vector). If this hangs, the blocker is in the single-core local IRQ/timer/trap path.

```bash
bash scripts/build/00b-deploy-overlay.sh
JOBS=$(nproc) MODULE_JOBS=1 bash scripts/build/build-kernel-bisect.sh irq-pipeline-minimal
bash scripts/flash/make-baseline-sdcard-img.sh <base_image>.img .build/build-k1-irq-pipeline-minimal .build/images
```

Flash to SD, boot on Jupiter, **capture full UART log**.

#### Step 2b: Analyze UART output

Expected outcomes:

| Outcome | Interpretation | Next Step |
|---------|---------------|-----------|
| Kernel banner appears, then hang | Pipeline init OK, later path broken | Check timer/tick/replay |
| No kernel banner, reset to OpenSBI | Very early pipeline failure | Check trap entry, early IRQ dispatch |
| Reaches userspace | Minimal pipeline works! | Promote to `irq-pipeline-only` |
- `irq-pipeline-noidle`
- `irq-pipeline-nosmp`
- `irq-pipeline-only`

#### Step 2c: If minimal hangs — targeted debug

Enable debug prints in the high-risk files:

1. **[`kernel-overlay/arch/riscv/kernel/irq_pipeline.c`](kernel-overlay/arch/riscv/kernel/irq_pipeline.c):** Change `if (false && irq == 20)` to `if (true)` to enable `BOOTDBG` prints
2. **[`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h):** Change `if (false)` to `if (true)` for `BOOTDBG` prints in `arch_handle_irq_pipelined()`
3. **Add early printk** in `arch_irq_pipeline_init()` to confirm pipeline init runs
4. **Boot with `evl_debug`** on kernel command line

**Exit criteria:**
- At least one IRQ-pipeline variant reaches userspace on Jupiter, OR
- UART log pinpoints the exact failure point (timer stall, trap corruption, PLIC misrouting)

---

### Phase 3: PLIC Driver Pipeline Audit (2–3 days)

**Goal:** Ensure the SpacemiT PLIC driver correctly interacts with the Dovetail IRQ pipeline.

**Rationale:** QEMU virt uses a simple HTIF/PLIC model. The SpacemiT K1 has a custom PLIC driver. If IRQ pipeline works on QEMU but not Jupiter, the PLIC driver is a prime suspect.

**Actions:**

1. **Diff the SpacemiT PLIC driver** against upstream `irq-sifive-plic.c`:
   ```bash
   diff .build/linux-k1/drivers/irqchip/irq-sifive-plic.c kernel-overlay/drivers/irqchip/irq-sifive-plic.c
   ```

2. **Check for pipeline-required hooks:**
   - Does the PLIC driver call `irq_set_handler_data()` or `irq_domain_alloc_irqs()`?
   - Does it support `IRQF_OOB` flag for out-of-band IRQ registration?
   - Does `plic_irq_enable()` / `plic_irq_disable()` go through the pipeline-aware `irq_chip` ops?

3. **Compare with the EVL reference tree's PLIC driver** (if RISC-V PLIC patches exist in `linux-evl`)

4. **Add pipeline-aware `irq_chip` ops** if missing:
   - `irq_chip.irq_enable` → must use `irq_pipeline_enable()` pattern
   - `irq_chip.irq_disable` → must use `irq_pipeline_disable()` pattern
   - `irq_chip.irq_ack` / `irq_chip.irq_eoi` → must be pipeline-safe

5. **Test on QEMU first**, then on Jupiter

**Exit criteria:**
- PLIC driver diff documented
- Any required pipeline modifications identified and implemented
- QEMU `irq-pipeline` still boots after PLIC changes

---

### Phase 4: Timer/CLINT Pipeline Audit (2–3 days)

**Goal:** Ensure the RISC-V timer interrupt path is pipeline-correct on K1.

**Actions:**

1. **Audit `drivers/clocksource/timer-riscv.c`** in the SpacemiT tree for:
   - Does it use `clockevents_config_and_register()` or a pipeline-aware variant?
   - Does the timer handler call `irq_pipeline_enter()` / `irq_pipeline_exit()`?
   - Is `tick_proxy` enabled for the RISC-V clockevent device?

2. **Check if SpacemiT has a custom CLINT driver** that deviates from upstream

3. **Verify `arch_steal_pipelined_tick()`** works correctly with the K1 timer:
   - The SR_PIE fix is in place, but verify the timer IRQ cause number matches what the pipeline expects

4. **Add early timer debug:**
   - Print when `riscv_timer_interrupt()` fires under pipeline
   - Print whether the tick is stolen or delivered to in-band

**Exit criteria:**
- Timer interrupt path documented
- Timer ticks advance `jiffies` correctly under pipeline on QEMU
- Timer behavior on Jupiter confirmed via UART

---

### Phase 5: Dovetail Without EVL (2–3 days)

**Goal:** Prove that alternate scheduling plumbing does not break basic boot.

**Prerequisite:** At least one IRQ-pipeline variant boots on Jupiter (Phase 2 exit).

**Actions:**

```bash
JOBS=$(nproc) MODULE_JOBS=1 bash scripts/build/build-kernel-bisect.sh dovetail-only
bash scripts/flash/make-baseline-sdcard-img.sh <base_image>.img .build/build-k1-dovetail .build/images
```

Test in order:
1. `dovetail-only`
2. `dovetail-noidle`
3. `dovetail-nosmp`
4. `evl-off`

**Focus files:**
- [`kernel-overlay/arch/riscv/include/asm/dovetail.h`](kernel-overlay/arch/riscv/include/asm/dovetail.h) — currently has stubbed `arch_dovetail_switch_*()` hooks
- [`kernel-overlay/arch/riscv/include/asm/mmu_context.h`](kernel-overlay/arch/riscv/include/asm/mmu_context.h) — `switch_oob_mm()` is minimal

**Exit criteria:**
- `dovetail-only` or one reduced variant boots on Jupiter
- No silent deadlock from timer/IPI/trap routing under Dovetail

---

### Phase 6: EVL Core Minimal Bring-up (2–3 days)

**Goal:** Add EVL on top of a booting Dovetail kernel.

**Prerequisite:** Dovetail boots on Jupiter (Phase 5 exit).

**Actions:**

```bash
JOBS=$(nproc) MODULE_JOBS=1 bash scripts/build/build-kernel-bisect.sh full-evl
bash scripts/flash/make-baseline-sdcard-img.sh <base_image>.img .build/build-k1-evl .build/images
```

Start with a reduced EVL config:
- `CONFIG_EVL=y`
- No optional EVL proxy/xbuf/poll/latmon extras at first
- Keep debug enabled

**Board-side checks:**
```bash
dmesg | grep -i "evl\|dovetail\|irq pipeline"
ls /sys/devices/virtual/evl/
cat /proc/evl/version
```

**Exit criteria:**
- Board boots with `CONFIG_EVL=y`
- EVL announces itself in boot log

---

### Phase 7: EVL Userspace and Functional Validation (3–5 days)

**Goal:** Validate that the kernel port is usable, not merely bootable.

**Actions:**

1. Build and deploy `libevl` for RISC-V:
   ```bash
   bash scripts/build/04-build-sdk.sh
   ```

2. Run `evl check` on Jupiter

3. Run `latmus` latency test:
   ```bash
   evl test latmus -t irq
   ```

4. Replace FPU/Vector placeholders:
   - Implement proper FPU save/restore in [`kernel-overlay/arch/riscv/include/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/asm/evl/fptest.h)
   - Implement userspace FPU test ABI in [`kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h)

5. Calibrate clock gravity for K1

**Exit criteria:**
- `evl check` passes
- No trap/FPU corruption under EVL self-tests
- Bounded IRQ latency on Jupiter (< 50 µs worst-case)

---

### Phase 8: s-aiotm Integration (ongoing)

**Goal:** Enable the four s-aiotm capabilities on the Jupiter + EVL platform.

This is the long-term integration work that depends on all previous phases succeeding.

---

## 6. Summary: Current Position and Next Move

```
                    COMPLETED                     REMAINING
                    ─────────                     ─────────
Phase 0: Gold baseline     ✅  ──→  
Phase 1: Vanilla kernel    ✅  ──→  
Phase 2: IRQ pipeline      ❌  ←── YOU ARE HERE
Phase 3: PLIC audit        ⬜  ──→  
Phase 4: Timer audit       ⬜  ──→  
Phase 5: Dovetail w/o EVL  ⬜  ──→  
Phase 6: EVL core          ⬜  ──→  
Phase 7: EVL userspace     ⬜  ──→  
Phase 8: s-aiotm           ⬜  ──→  Final goal
```

**The single most important next action is:**

> **Build `irq-pipeline-minimal`, flash it to Jupiter, and capture the full UART log.**

This is the narrowest possible test that can tell us whether the IRQ pipeline can work at all on the K1 hardware. The result determines everything that follows:

- If it boots → promote upward through `irq-pipeline-only` → `dovetail-only` → `full-evl`
- If it hangs → the UART log will reveal whether the blocker is in trap entry, timer delivery, PLIC dispatch, or early pipeline state — and we fix that specific path before moving on

---

## 7. How to Use UART Feedback Effectively

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

## 8. Key Files to Watch (Class C — Highest Risk)

These are the files most likely causing the Jupiter boot hang under `IRQ_PIPELINE`:

| File | What It Controls | Why Risky |
|------|-----------------|-----------|
| [`kernel-overlay/arch/riscv/include/asm/irqflags.h`](kernel-overlay/arch/riscv/include/asm/irqflags.h) | `native_*()` hardware ops, includes `irq_pipeline.h` | If `arch_local_*()` bypasses stall-bit, OOB stage races with in-band |
| [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h) | `arch_local_*()` via stall-bit, `arch_steal_pipelined_tick()` | SR_PIE fix is critical; any mistake here steals all ticks or none |
| [`kernel-overlay/arch/riscv/kernel/irq_pipeline.c`](kernel-overlay/arch/riscv/kernel/irq_pipeline.c) | `arch_do_IRQ_pipelined()`, `irq_cpuidle_control()` | Hard IRQ save/restore around replay; cpuidle blocking |
| [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c) | IRQ dispatch routing, syscall context fix | Routes IRQs through pipeline; `riscv_syscall_irq_context_fix()` is aggressive |
| [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c) | OOB IPI, `ipi_irq_base` | SMP IPI under pipeline untested on hardware |
| [`kernel-overlay/drivers/irqchip/irq-sifive-plic.c`](kernel-overlay/drivers/irqchip/irq-sifive-plic.c) | PLIC interrupt controller | May lack pipeline-aware `irq_chip` ops |

---

## 9. Comparison: QEMU vs Jupiter — Why QEMU Boots But Jupiter Doesn't

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
1. **PLIC not pipeline-aware** — IRQ dispatch may bypass the pipeline
2. **SpacemiT clock/power domain drivers** — may call `local_irq_disable()` expecting hardware masking, but get stall-bit virtualization instead
3. **MMC driver** — if the SD card controller IRQ doesn't flow through the pipeline, the rootfs can't be mounted
4. **Display/GPU driver** — may stall the pipeline during framebuffer init

---

## 10. Code Changes Applied (2026-04-29 Session)

### 10.1 Critical Fix: PLIC `IRQCHIP_PIPELINE_SAFE` missing

**File:** `kernel-overlay/drivers/irqchip/irq-sifive-plic.c`

Both `plic_edge_chip` and `plic_chip` were missing `IRQCHIP_PIPELINE_SAFE` in their `.flags` field. Without this flag, `irq_set_chip()` fires a WARN for every PLIC IRQ, and the pipeline may not properly route external interrupts. Since the PLIC handles ALL external interrupts on K1 (MMC, UART, display, etc.), this is very likely the primary cause of the Jupiter boot hang.

**Change:** Added `IRQCHIP_PIPELINE_SAFE` to both structures in both `CONFIG_SOC_SPACEMIT` and non-SpacemiT code paths.

### 10.2 Fix: PCIe MSI `IRQCHIP_PIPELINE_SAFE` missing

**File:** `kernel-overlay/drivers/pci/controller/dwc/pcie-k1x.c`

Both `k1x_msi_irq_chip` and `k1x_pcie_msi_bottom_irq_chip` were missing `IRQCHIP_PIPELINE_SAFE`.

**Change:** Added `IRQCHIP_PIPELINE_SAFE` to both structures.

### 10.3 Diagnostic: BOOTDBG prints enabled

**File:** `kernel-overlay/arch/riscv/kernel/irq_pipeline.c`

- Changed `if (false && irq == 20)` → `if (irq == 20)` for timer IRQ tracing in `arch_do_IRQ_pipelined()`
- Added `pr_info("IRQ pipeline: arch_irq_pipeline_init() called on CPU%d\n", ...)` to the previously empty `arch_irq_pipeline_init()`

**File:** `kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`

- Changed all `if (false)` BOOTDBG prints in `arch_handle_irq_pipelined()` to rate-limited prints (first 20 IRQs only)
- This shows the cause, dispatch result, and `handle_arch_irq` flow for early IRQs

### 10.4 Fix: `evl_debug` early param now enables runtime trace

**File:** `kernel-overlay/arch/riscv/kernel/evl_debug.c`

The `evl_debug` kernel parameter was setting `riscv_evl_early_debug_enabled = true` but leaving `riscv_evl_runtime_trace_enabled = false`, which meant all `EVLDBG` traces (SBI-based early UART output) were dead.

**Change:** Now sets both flags to `true`, and prints a confirmation message.

### 10.5 Config: `evl_debug` added to kernel command line

**File:** `configs/extlinux.conf`

Added `evl_debug` to the `append` line so SBI-based early debug traces are active from boot. This is critical because `riscv_evl_early_puts()` uses SBI ecall to write directly to UART — it works even before the kernel console subsystem initializes.

### 10.6 Already correct (verified, no change needed)

- `irq-riscv-intc.c`: both `riscv_intc_chip` and `andes_intc_chip` already have `IRQCHIP_PIPELINE_SAFE`
- `regmap-irq.c`: already adds `IRQCHIP_PIPELINE_SAFE` at runtime (line 741)
- `kernel/irq/pipeline.c`: `sirq_chip` is the pipeline's own virtual controller, doesn't need the flag

---

## 11. Build and Test Instructions

### Step 1: Re-deploy overlay and build irq-pipeline-minimal

```bash
# From the repo root
bash scripts/build/00b-deploy-overlay.sh

# Configure with the minimal IRQ pipeline defconfig
CONFIG_FRAGMENT=configs/k1_irq_pipeline_minimal_defconfig \
  bash scripts/build/02-configure.sh

# Build the kernel
bash scripts/build/03-build-kernel.sh
```

### Step 2: Create kernel-only SD image

```bash
# Replace with your actual Bianbu base image path
bash scripts/flash/make-baseline-sdcard-img.sh /path/to/bianbu-base-image.img
```

### Step 3: Flash and boot on Jupiter

```bash
# Flash to SD card (replace /dev/sdX with your device)
sudo dd if=output/baseline-sdcard.img of=/dev/sdX bs=4M status=progress
sudo eject /dev/sdX
```

### Step 4: Capture UART log

Connect UART debug cable (115200 8N1) and capture the full boot output. Key markers to look for:

1. `IRQ pipeline: arch_irq_pipeline_init() called on CPU0` — confirms pipeline init ran
2. `EVLDBG arch_handle_irq_pipelined entry` — first IRQ through the pipeline
3. `BOOTDBG arch_handle_irq_pipelined before_dispatch cause=...` — IRQ cause numbers
4. `BOOTDBG arch_do_IRQ_pipelined enter irq=20` — timer IRQ replay working
5. `riscv-timer: BOOTDBG riscv_timer_starting_cpu` — timer brought up
6. Any WARN/panic/oops — copy the full stack trace

### Step 5: Share the UART log

Paste the full UART output so I can analyze the failure point and determine the next fix.

---

## 12. Expected Outcomes

| Scenario | Meaning | Next Step |
|----------|---------|-----------|
| Boot reaches login prompt | `IRQCHIP_PIPELINE_SAFE` fix was sufficient | Promote to `irq-pipeline-nosmp`, then `irq-pipeline-only` |
| Boot hangs but UART shows IRQ flow | Pipeline is working but something else blocks | Analyze the last IRQ/initcall before hang |
| Boot hangs with no UART output after OpenSBI | Pipeline breaks before console init | Need SBI-level early debug or GDB |
| Kernel panic with stack trace | Specific driver/hook crashes | Fix the identified code path |
