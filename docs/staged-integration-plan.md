# Staged Integration Plan for Xenomai 4 / EVL on Milk-V Jupiter

## Goal

Make the Jupiter bring-up reproducible and low-risk by treating:

1. image bootability,
2. RISC-V IRQ pipeline bring-up,
3. Dovetail alternate scheduling,
4. EVL core enablement,
5. userspace validation

as separate milestones.

This document intentionally rejects the "full EVL image first" approach.

## Current Assessment

The repository is already strong in two areas:

- the build pipeline is now reproducible from git
- the flash pipeline already supports staged boot profiles

The main remaining risk is not image assembly anymore, but architecture
semantics in the RISC-V Dovetail/EVL port.

In particular, the following files are still provisional and should not be
treated as "production-ready EVL on RISC-V":

- `kernel-overlay/arch/riscv/include/asm/dovetail.h`
- `kernel-overlay/arch/riscv/include/asm/mmu_context.h`
- `kernel-overlay/arch/riscv/include/asm/evl/fptest.h`
- `kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h`

## Design Rules

### Rule 1: first prove boot, then prove real-time semantics

A bootable image with a locally built non-EVL kernel is more valuable than an
EVL-enabled image that hangs at the splash screen.

### Rule 2: follow the official Dovetail porting order

Per the Xenomai 4 documentation, the correct sequence is:

1. interrupt pipeline
2. alternate scheduling
3. EVL core
4. EVL library

### Rule 3: keep bootflow changes minimal until the kernel itself is trusted

Prefer:

- `kernel-only`
- `kernel-modules`

before:

- `env-debug`
- `boot-debug`
- `full-evl`

### Rule 4: do not trust local RISC-V stubs as final design

Anything touching:

- IRQ masking
- trap handling
- MM context switching
- OOB scheduler hand-off
- FPU / Vector handling

must be justified against upstream or public mailing-list work, not only
against build success.

## Phase Plan

### Phase 0: Golden Base Image

Objective:

- prove the vendor base image boots on the exact board/storage path used for
  testing

Actions:

- flash the untouched official Bianbu / buildroot image
- record UART and HDMI behavior
- save `extlinux.conf`, boot partition listing, and rootfs UUID

Exit criteria:

- board reaches shell or login prompt reliably
- serial console is confirmed working

### Phase 1: Locally Built Vanilla Kernel

Objective:

- prove that a locally built non-EVL kernel from the same vendor tree still
  boots when injected into the base image

Actions:

- build `vanilla-k1` using `scripts/build/build-kernel-bisect.sh`
- create a `kernel-only` image from that build
- if needed, test `kernel-modules` with the same kernel

Why this matters:

- if this fails, the problem is not EVL at all
- it isolates image replacement, kernel versioning, DTB placement, and module
  ABI issues first

Exit criteria:

- `vanilla-k1 + kernel-only` boots
- `vanilla-k1 + kernel-modules` also boots if modules are required

### Phase 2: IRQ Pipeline Only

Objective:

- prove that the interrupt pipeline can boot before adding alternate
  scheduling or EVL

Actions:

- build and boot these variants in order:
  1. `irq-pipeline-only`
  2. `irq-pipeline-noidle`
  3. `irq-pipeline-nosmp`
  4. `irq-pipeline-minimal`

Preferred image profile:

- start with `kernel-only`
- use `kernel-modules` only if the first result suggests module ABI mismatch

Key observation targets:

- timer tick progress
- jiffies moving
- no freeze at splash / initramfs hand-off
- no IPI storm or interrupt starvation

Exit criteria:

- at least one IRQ-pipeline-only variant reaches userspace

Current evidence:

- `vanilla-k1` boots on Jupiter
- `irq-pipeline-only`, `irq-pipeline-noidle`, and `irq-pipeline-nosmp`
  all hang at the Bianbu logo

Interpretation:

- the main blocker is now below EVL and below alternate scheduling
- disabling SMP and idle did not avoid the hang, so the next focus should be
  the single-core local IRQ/timer/trap path itself
- `irq-pipeline-minimal` is the next narrowing step

### Phase 3: Dovetail Without EVL

Objective:

- prove that alternate scheduling plumbing does not break basic boot before
  adding the EVL core

Actions:

- build and boot these variants in order:
  1. `dovetail-only`
  2. `dovetail-noidle`
  3. `dovetail-nosmp`
  4. `evl-off`

Focus files:

- `arch/riscv/include/asm/irqflags.h`
- `arch/riscv/include/asm/irq_pipeline.h`
- `arch/riscv/kernel/irq_pipeline.c`
- `arch/riscv/kernel/traps.c`
- `arch/riscv/kernel/smp.c`
- `arch/riscv/include/asm/mmu_context.h`
- `arch/riscv/include/asm/dovetail.h`

Exit criteria:

- `dovetail-only` or one reduced variant boots
- no silent deadlock attributable to timer/IPI/trap routing

### Phase 4: EVL Core Minimal Bring-up

Objective:

- add EVL only after Dovetail itself is shown boot-safe

Actions:

- start from the first booting Dovetail variant
- create a reduced EVL fragment:
  - `CONFIG_EVL=y`
  - no optional EVL proxy/xbuf/poll/latmon extras at first
  - keep debug enabled
- do not enable `full-evl` image profile yet

Required kernel-side checks:

- `dmesg | grep -i "evl\\|dovetail\\|irq pipeline"`
- `/proc/config.gz`
- `/sys/devices/virtual/evl/`

Exit criteria:

- board boots with `CONFIG_EVL=y`
- EVL announces itself in boot log

### Phase 5: EVL Userspace and Functional Validation

Objective:

- validate that the kernel port is usable, not merely bootable

Actions:

- build and deploy `libevl`
- run `evl check`
- run `latmus`
- only then evaluate proxy drivers and fieldbus-oriented features

Exit criteria:

- `evl check` passes
- no immediate trap/FPU corruption under EVL self-tests

## Mandatory Technical Work Before Claiming Full EVL on RISC-V

### 1. Replace placeholder FPU / Vector support

These files are currently placeholders:

- `arch/riscv/include/asm/evl/fptest.h`
- `arch/riscv/include/uapi/asm/evl/fptest.h`

Until replaced, EVL stress validation should be considered incomplete.

### 2. Rework or upstream-align `switch_oob_mm()`

Current code simply maps:

```c
switch_oob_mm(prev, next, task) { switch_mm(prev, next, task); }
```

That may be enough for build or early boot, but should not be assumed to be the
final dovetail-aware MM design for RISC-V.

### 3. Rework or upstream-align `arch_dovetail_switch_*()`

Current code leaves architecture switch hooks empty. That is acceptable only as
temporary bring-up scaffolding.

### 4. Add a QEMU riscv64 validation lane

Before trusting Jupiter-only failures, add a `QEMU virt` lane for:

- `irq-pipeline-only`
- `dovetail-only`
- `full-evl` later

This separates generic RISC-V port issues from K1-specific boot issues.

## Recommended Immediate Next Step

Do not flash another `full-evl` image first.

Instead:

1. build `vanilla-k1`
2. build `irq-pipeline-only`
3. build `irq-pipeline-noidle`
4. build `irq-pipeline-nosmp`
5. create `kernel-only` images for each
6. test them in that exact order

Only after one IRQ-pipeline variant boots should we move upward to
`dovetail-only` and then EVL.
