# Next-Step Integration Plan for Xenomai 4 / EVL on Milk-V Jupiter

## Purpose

This note turns the repository findings into an execution order that is narrow,
testable, and aligned with the official Xenomai 4 bring-up philosophy:

1. prove image bootability
2. prove generic RISC-V IRQ pipeline semantics
3. prove Dovetail alternate scheduling hooks
4. prove EVL core boot
5. prove EVL userspace and latency behavior

It intentionally rejects the idea of repeatedly generating a full EVL SD image
before the lower layers are trusted.

## Executive Conclusion

At this point, the repository already demonstrates three useful things:

- the kernel can be configured and built reproducibly
- the SD-card image generator is now staged and conservative enough
- the remaining blocker is most likely in the RISC-V runtime path, not in image assembly

So the immediate task is **not** “make a richer image”. The immediate task is:

**find the first bootable kernel slice above vendor vanilla and below full EVL.**

## Working Diagnosis

### What is likely already good enough

The `kernel-only` and `kernel-modules` profiles in [`scripts/flash/make-full-sdcard-img.sh`](scripts/flash/make-full-sdcard-img.sh) preserve the base image bootflow. That makes them suitable for disciplined bisect work.

Therefore, when a staged image still hangs at the Bianbu logo, the most likely cause is now one of:

- local IRQ flag virtualization
- timer interrupt steal/replay logic
- trap entry/exit state corruption
- pipelined SMP/IPI interaction
- Dovetail MM / scheduler hand-off later in the stack

### Most likely blocker order

1. `IRQ_PIPELINE`
2. timer / trap / deferred IRQ replay correctness
3. Dovetail arch hand-off
4. EVL core
5. EVL FPU/vector completion

This matches both the public Xenomai porting order and the repository’s own current evidence.

## Stage 0 — Preserve a Gold Standard

Before any more integration work, keep one untouched, known-good vendor image and one set of recorded evidence from that image.

Required evidence:

- boot partition listing
- current `extlinux.conf`
- UART log from a successful boot
- `uname -a`
- `/proc/cmdline`
- rootfs UUID

Reason:

This becomes the fixed comparison point for every later stage.

## Stage 1 — Prove Local Kernel Injection Without EVL

Goal:

Show that a locally built, non-EVL kernel from the same SpacemiT source still boots when inserted into the base image.

Use:

- [`scripts/build/build-kernel-bisect.sh`](scripts/build/build-kernel-bisect.sh)
- variant: `vanilla-k1`
- image profile: `kernel-only`
- fallback image profile: `kernel-modules`

Commands:

```bash
bash scripts/build/build-kernel-bisect.sh vanilla-k1

bash scripts/flash/make-baseline-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

If `kernel-only` hangs, try:

```bash
bash scripts/flash/make-kernel-modules-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

Exit criteria:

- locally built `vanilla-k1` boots on Jupiter

Interpretation:

- if this fails, stop all EVL work temporarily: the issue is below EVL and possibly below Dovetail too

## Stage 2 — Find the First Bootable IRQ-Pipeline Slice

Goal:

Prove whether the generic RISC-V IRQ pipeline path can boot at all on Jupiter.

Test order:

1. `irq-pipeline-only`
2. `irq-pipeline-noidle`
3. `irq-pipeline-nosmp`
4. `irq-pipeline-minimal`

Commands:

```bash
bash scripts/build/build-kernel-bisect.sh irq-pipeline-only
bash scripts/build/build-kernel-bisect.sh irq-pipeline-noidle
bash scripts/build/build-kernel-bisect.sh irq-pipeline-nosmp
bash scripts/build/build-kernel-bisect.sh irq-pipeline-minimal
```

For each build, generate first a `kernel-only` image. Only if the symptom still smells like module ABI mismatch, promote that same build to `kernel-modules`.

Observation focus:

- does the kernel advance beyond splash?
- does UART show timer/tick progress?
- does the machine reset back to firmware?
- does SMP/noidle/no-PM change the failure mode?

Interpretation rules:

- if `irq-pipeline-only` fails but `irq-pipeline-minimal` boots, the next target is idle/SMP/timer integration, not EVL
- if even `irq-pipeline-minimal` fails, the blocker is likely in the single-core local IRQ/timer/trap path
- if any IRQ-pipeline variant boots, freeze that variant as the new promotion baseline

## Stage 3 — Mandatory QEMU `virt` Lane

Goal:

Separate generic RISC-V architectural problems from Jupiter-only platform problems.

Use:

- [`scripts/build/build-qemu-virt-bisect.sh`](scripts/build/build-qemu-virt-bisect.sh)
- [`scripts/qemu/run-riscv64-virt.sh`](scripts/qemu/run-riscv64-virt.sh)
- [`docs/qemu-virt.md`](docs/qemu-virt.md)

Recommended order:

1. `vanilla-qemu`
2. `irq-pipeline-qemu`
3. `irq-pipeline-pmoff-qemu`
4. `irq-pipeline-tickoff-qemu`
5. `irq-pipeline-nosmp-qemu`
6. `irq-pipeline-noidle-qemu`
7. `irq-pipeline-minimal-qemu`

Then only if one of those is stable:

8. `dovetail-qemu`
9. `dovetail-noidle-qemu`
10. `dovetail-nosmp-qemu`
11. `full-evl-qemu`

Command pattern:

```bash
bash scripts/build/build-qemu-virt-bisect.sh irq-pipeline-qemu
QEMU_NO_REBOOT=1 APPEND="evl_debug" \
  bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

Exit criteria:

- at least one QEMU IRQ-pipeline variant reaches a reliable boot stage or emits stable early trace evidence

Interpretation:

- if QEMU already fails, fix generic RISC-V pipeline semantics before spending more Jupiter cycles
- if QEMU works and Jupiter fails, prioritize SpacemiT-specific timer/interrupt/boot interactions

## Stage 4 — Dovetail Without EVL

Only start this stage after Stage 2 or Stage 3 has produced a trusted IRQ-pipeline baseline.

Goal:

Validate alternate scheduling and trap/MM hand-off without the full EVL core.

Test order:

1. `dovetail-only`
2. `dovetail-noidle`
3. `dovetail-nosmp`
4. `evl-off`

Focus files for review and possible patch refinement:

- [`kernel-overlay/arch/riscv/include/asm/irqflags.h`](kernel-overlay/arch/riscv/include/asm/irqflags.h)
- [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h)
- [`kernel-overlay/arch/riscv/kernel/irq_pipeline.c`](kernel-overlay/arch/riscv/kernel/irq_pipeline.c)
- [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c)
- [`kernel-overlay/arch/riscv/kernel/smp.c`](kernel-overlay/arch/riscv/kernel/smp.c)
- [`kernel-overlay/arch/riscv/include/asm/mmu_context.h`](kernel-overlay/arch/riscv/include/asm/mmu_context.h)
- [`kernel-overlay/arch/riscv/include/asm/dovetail.h`](kernel-overlay/arch/riscv/include/asm/dovetail.h)

Exit criteria:

- one Dovetail variant boots without EVL enabled

## Stage 5 — EVL Core Minimal Bring-up

Only after Dovetail is shown boot-safe.

Goal:

Enable the minimum EVL core and verify that it announces itself during boot.

Guidelines:

- begin from the first booting Dovetail variant
- keep debug enabled
- do not jump straight to aggressive rootfs patching
- keep image profile conservative unless bootflow changes are directly required

Checks on target:

```bash
dmesg | grep -i "evl\|dovetail\|irq pipeline"
zcat /proc/config.gz | grep -E "CONFIG_DOVETAIL|CONFIG_EVL|CONFIG_IRQ_PIPELINE"
ls /sys/devices/virtual/evl/
```

Exit criteria:

- board boots
- EVL announces core startup
- EVL interfaces exist in sysfs or procfs

## Stage 6 — Userspace EVL and Functional Validation

Only after EVL kernel boot is stable.

Goal:

Validate that the port is usable, not just bootable.

Use:

- [`scripts/build/04-build-sdk.sh`](scripts/build/04-build-sdk.sh) only when a stronger base image is actually needed
- `libevl` cross-build and deployment

Board-side test order:

1. `evl check`
2. `evl test latmus -t irq`
3. periodic wakeup test
4. affinity and isolation tuning

Exit criteria:

- no immediate trap/FPU corruption
- no instant scheduler deadlock
- bounded latency measurements

## Known Incomplete Areas That Must Not Be Forgotten

### 1. FPU / Vector support is not complete

These files are explicit placeholders:

- [`kernel-overlay/arch/riscv/include/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/asm/evl/fptest.h)
- [`kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h`](kernel-overlay/arch/riscv/include/uapi/asm/evl/fptest.h)

So even after EVL boots, stress-validation is not complete until real RISC-V FPU handling is aligned with upstream/community work.

### 2. MM switch logic is still provisional

[`kernel-overlay/arch/riscv/include/asm/mmu_context.h`](kernel-overlay/arch/riscv/include/asm/mmu_context.h) currently maps `switch_oob_mm()` directly to `switch_mm()`. That may be acceptable for bring-up, but should be treated as temporary until validated against public RISC-V Dovetail work.

### 3. Dovetail switch hooks are still stubs

[`kernel-overlay/arch/riscv/include/asm/dovetail.h`](kernel-overlay/arch/riscv/include/asm/dovetail.h) keeps `arch_dovetail_switch_prepare()` and `arch_dovetail_switch_finish()` effectively empty. That is acceptable only as bring-up scaffolding.

## Immediate Action List

The next concrete sequence should be:

1. build `vanilla-k1`
2. verify `vanilla-k1 + kernel-only`
3. if needed, verify `vanilla-k1 + kernel-modules`
4. build and test `irq-pipeline-only`
5. build and test `irq-pipeline-noidle`
6. build and test `irq-pipeline-nosmp`
7. build and test `irq-pipeline-minimal`
8. in parallel, run the same narrowing strategy in QEMU `virt`
9. only after one IRQ-pipeline baseline is trusted, move to `dovetail-only`
10. only after one Dovetail baseline is trusted, move to EVL core

## Final Principle

For this port, success is not “a big image was generated”.

Success is:

- a minimal stage boots,
- the next minimal stage also boots,
- each promotion is justified,
- and only then is Xenomai 4 / EVL considered genuinely integrated on SpacemiT K1.
