# RISC-V Upstream Patch Map for EVL / Dovetail

## Purpose

This note captures the current public upstream status of `RISC-V` support for
`Xenomai 4 / EVL`, then maps that status onto this repository.

The main design rule is simple:

- keep using `asm-generic` bridge headers where upstream does the same
- do **not** infer deep `RISC-V` behavior from `arm64`
- treat `irq`, `trap`, `mm`, `scheduler`, and `FPU` integration as
  `RISC-V`-specific bring-up work

## External Status Snapshot

### 1. Official EVL port matrix still does not list RISC-V

As of the EVL ports page last modified on `2025-11-08`, the official matrix
lists validated `arm`, `arm64`, and `x86_64` targets, but no `RISC-V` target.

This means `RISC-V` is not yet a publicly declared, stress-validated EVL port.

### 2. The official bring-up order matches what we are seeing locally

The EVL ports page says platform bring-up should proceed in this order:

1. `Dovetail`
2. `IRQ pipeline`
3. `Alternate scheduling`
4. `EVL core`
5. `EVL library`

That exactly matches the failure pattern we have been hitting: once `EVL` starts
building, the remaining blockers are in the `RISC-V` architecture hooks and in
the `Dovetail`-dependent core paths.

### 3. RISC-V Dovetail work was already active in late 2024

On `2024-11-04`, Philippe Gerum wrote that he had started a `Dovetail` branch
for the `RISC-V` port, forward-porting Tobias Schaffner's IRQ pipeline series
to `6.12-rc6`, and that a `QEMU riscv64` kernel was already booting with:

- `SMP`
- `PREEMPT_RT`
- `IRQ_PIPELINE`

He also said the next step was to pick the upper Dovetail layer already ported
by another contributor to enable `EVL` on top.

This is the strongest public signal that `RISC-V + Dovetail + EVL` is a real
upstream effort, not a thought experiment.

### 4. A full RISC-V patch wave appeared publicly in October 2025

The Xenomai mailing-list archive shows the following public series around
`2025-10-09` and `2025-10-10`:

- `PATCH dovetail 0/8 riscv: Add Dovetail support`
- `PATCH linux-evl 0/2 Add RISC-V support to EVL`
- `PATCH libevl build: add initial RISC-V support`
- `PATCH xenomai-images 0/2 Add RISC-V Architecture Support for EVL`

The `dovetail` thread titles are especially important because they show the
scope of work was not a header-only adaptation. The series explicitly covered:

- IRQ flag ordering fixes
- timer register save support
- initial co-kernel skeleton
- out-of-band trap handling
- dovetail-aware memory management
- KVM enablement

So the public upstream direction is clear: `RISC-V` support is expected to span
arch entry code, timer/IRQ delivery, MM switching, and scheduling hand-off.

## What This Means for This Repository

### Safe to keep

The following classes of changes are still the right approach here:

- `arch/riscv/include/dovetail/*.h` bridge headers including
  `asm-generic/evl/*` helpers
- `include/trace/events/evl.h`
- `kernel/evl/` subtree import
- generic EVL and Dovetail Kconfig / Makefile wiring
- generic time proxy support imported from `linux-evl`

These are not "pretending RISC-V is arm64". They are the same sort of generic
layering upstream EVL already uses across architectures.

### Must be treated as real RISC-V porting work

The following areas must now be handled as first-class `RISC-V` integration:

1. `arch/riscv/include/asm/irqflags.h`
2. `arch/riscv/include/asm/irq_pipeline.h`
3. `arch/riscv/kernel/irq_pipeline.c`
4. `arch/riscv/kernel/traps.c`
5. `arch/riscv/kernel/smp.c`
6. `arch/riscv/include/asm/mmu_context.h`
7. `kernel/sched/core.c`
8. `kernel/time/tick-proxy.c` interaction with `RISC-V` timer/IRQ paths
9. `arch/riscv/include/asm/evl/fptest.h`

These are the places where the public upstream patch subjects say the real work
lives, and they also match the files where our current build issues converge.

## Local File Mapping

This is the recommended mapping from the public upstream patch topics to this
repository:

| Upstream topic | Local landing zone |
|---|---|
| IRQ pipelining core | `kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`, `kernel-overlay/arch/riscv/kernel/irq_pipeline.c` |
| Interrupt flag semantics | `kernel-overlay/arch/riscv/include/asm/irqflags.h` |
| Out-of-band trap handling | `kernel-overlay/arch/riscv/kernel/traps.c` |
| Dovetail-aware MM | `kernel-overlay/arch/riscv/include/asm/mmu_context.h`, `kernel-overlay/kernel/sched/core.c` |
| Alternate scheduling hooks | `kernel-overlay/include/linux/dovetail.h`, `kernel-overlay/kernel/sched/core.c`, `kernel-overlay/kernel/dovetail.c` |
| Tick proxy / pipelined clockevents | `kernel-overlay/include/linux/clockchips.h`, `kernel-overlay/kernel/time/*` |
| EVL core on RISC-V | `kernel-overlay/arch/riscv/include/asm/evl/*`, `kernel-overlay/kernel/evl/*` |
| libevl RISC-V support | userspace SDK stage, not kernel bring-up |
| xenomai-images / QEMU support | optional validation lane, useful before Jupiter-only testing |

## Design Decisions Going Forward

### Decision 1: stop using arm64 as the semantic reference for deep arch logic

`arm64` remains useful as a style and layering reference, but no longer as the
behavioral reference for:

- interrupt masking rules
- trap entry / return rules
- MM switch behavior
- OOB scheduler hand-off
- FPU handling

Those must be aligned with `RISC-V`-specific upstream work.

### Decision 2: keep generic bridge headers unless RISC-V upstream says otherwise

Files like:

- `arch/riscv/include/dovetail/mm_info.h`
- `arch/riscv/include/dovetail/poll.h`
- `arch/riscv/include/dovetail/net.h`
- `arch/riscv/include/dovetail/netdevice.h`

are still good design, because upstream EVL already uses this bridge pattern on
other architectures.

### Decision 3: introduce a QEMU RISC-V validation lane before board-only trust

Because public upstream evidence shows `QEMU riscv64` was used during early
bring-up, we should add a `QEMU virt` validation lane before trusting Jupiter
results alone.

This is especially important because the current target board lacks UART access.

## Recommended Work Sequence

### Phase A: upstream-structure alignment

1. Finish documenting which current overlay changes correspond to each public
   `RISC-V` patch topic.
2. Audit `kernel-overlay/arch/riscv/` against that topic list.
3. Remove any local workaround that has no clear upstream analogue.

### Phase B: QEMU RISC-V baseline

1. Build a `QEMU virt`-oriented `RISC-V` EVL kernel from the same repository.
2. Confirm that `IRQ_PIPELINE`, `DOVETAIL`, and `EVL` all link together there.
3. Use that result to separate architecture bugs from SpacemiT-specific bugs.

### Phase C: SpacemiT K1 specialization

1. Check whether Jupiter still follows the standard `RISC-V` timer and local
   interrupt model closely enough for the upstream pipeline assumptions.
2. Audit SpacemiT-specific clock, interrupt, and boot-time paths for any
   deviation from the generic `RISC-V` bring-up flow.
3. Only then move to board boot validation.

## Practical Rule for Current Patches

When deciding whether a local change is acceptable, use this test:

- if it only wires generic EVL code into `RISC-V`, it is probably fine
- if it changes interrupt, trap, scheduler, MM, or FPU behavior, it must be
  justified against the public `RISC-V` bring-up direction

## Sources

- EVL ports status page:
  https://v4.xenomai.org/ports/index.html
- Philippe Gerum on `RISC-V` Dovetail bring-up, `2024-11-04`:
  https://yhbt.net/lore/xenomai/87plnbwchv.fsf@xenomai.org/
- Xenomai mailing-list archive showing `RISC-V` patch series in `2025-10`:
  https://lore-kernel.gnuweeb.org/xenomai/
