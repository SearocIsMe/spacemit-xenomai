# RISC-V Overlay Audit

## Purpose

This document classifies every file under `kernel-overlay/arch/riscv/` by:

- upstream relationship
- semantic risk
- public patch topic
- recommended next action

The goal is to focus future work on the files which carry real `RISC-V`
semantics, while leaving low-risk generic bridge layers alone unless needed.

## Legend

- `Bridge`: mostly forwards to `asm-generic/evl/*`, low semantic risk
- `Glue`: wires EVL/Dovetail into the `RISC-V` tree, moderate risk
- `Core`: changes `RISC-V` runtime behavior, high risk
- `Stub`: local placeholder needed for build, but not yet trustworthy for real
  runtime validation

## File Audit

| File | Class | Upstream relationship | Topic | Risk | Current assessment |
|---|---|---|---|---|---|
| `arch/riscv/Kconfig` | Glue | diverges from `linux-evl` due to vendor tree additions | feature enablement | medium | Needed, but should be kept minimal around EVL knobs |
| `arch/riscv/kernel/Makefile` | Glue | diverges from `linux-evl` and vendor tree | build wiring | low | Mostly safe; only EVL-specific line should matter |
| `arch/riscv/include/dovetail/mm_info.h` | Bridge | local bridge | mm state bridge | low | Good pattern, keep |
| `arch/riscv/include/dovetail/poll.h` | Bridge | local bridge | poll bridge | low | Good pattern, keep |
| `arch/riscv/include/dovetail/net.h` | Bridge | local bridge | net bridge | low | Good pattern, keep |
| `arch/riscv/include/dovetail/netdevice.h` | Bridge | local bridge | netdevice bridge | low | Good pattern, keep |
| `arch/riscv/include/dovetail/irq.h` | Bridge | local bridge | irq bridge | low | Good pattern, keep |
| `arch/riscv/include/dovetail/thread_info.h` | Bridge | local bridge | oob thread state bridge | low | Good pattern, keep |
| `arch/riscv/include/asm/thread_info.h` | Glue | derived from `linux-evl` delta | thread flags / oob state | medium | Plausible, but should be audited against public RISC-V series |
| `arch/riscv/include/asm/syscall.h` | Glue | derived from `linux-evl` delta | syscall arg extraction | low | `syscall_get_arg0()` addition looks reasonable |
| `arch/riscv/include/asm/irqflags.h` | Core | diverges from `linux-evl` | interrupt flag semantics | high | One of the most important files in the port |
| `arch/riscv/include/asm/irq_pipeline.h` | Core | local | IRQ pipeline arch semantics | high | One of the most important files in the port |
| `arch/riscv/kernel/irq_pipeline.c` | Core | local | IRQ replay / pipeline init | high | Needs close alignment with public RISC-V IRQ pipeline direction |
| `arch/riscv/kernel/traps.c` | Core | derived from `linux-evl` delta plus vendor changes | out-of-band trap handling | high | Critical path; must preserve SpacemiT behavior while adding Dovetail |
| `arch/riscv/kernel/smp.c` | Core | derived from `linux-evl` delta plus vendor changes | OOB IPI / resched | high | Critical for alternate scheduling on SMP |
| `arch/riscv/include/asm/mmu_context.h` | Core | local delta over both trees | dovetail-aware MM | high | Current `switch_oob_mm()` is minimal and should be treated as provisional |
| `arch/riscv/include/asm/dovetail.h` | Core | local | arch dovetail hooks / trap mediation | high | Contains stubbed switch hooks; currently build-oriented, not validated runtime logic |
| `arch/riscv/include/asm/evl/thread.h` | Glue | local | EVL thread arch helper | medium | Small but architecture-specific; likely fine |
| `arch/riscv/include/asm/evl/syscall.h` | Glue | local | EVL syscall ABI helper | medium | Reasonable shape, but still local |
| `arch/riscv/include/asm/evl/calibration.h` | Stub | local | default clock gravity | medium | Build helper only; runtime number is not yet validated on K1 |
| `arch/riscv/include/asm/evl/fptest.h` | Stub | local | FPU/vector validation | high | Placeholder only; this is a known unresolved area |
| `arch/riscv/include/uapi/asm/evl/fptest.h` | Stub | local | userspace FPU/vector test ABI | high | Placeholder only; must be replaced for real EVL validation |
| `arch/riscv/include/asm/evl/thread.h` | Glue | local | breakpoint detection | low | Small and likely fine |

## Most Important Findings

### 1. The bridge headers are not the main risk

The `dovetail/*.h` bridge files we added are exactly the kind of layering EVL
already uses on other architectures. They are not the place where this port is
most likely to fail.

### 2. The real risk is concentrated in six files

These are the files that most likely determine whether `RISC-V + EVL` actually
works:

1. `arch/riscv/include/asm/irqflags.h`
2. `arch/riscv/include/asm/irq_pipeline.h`
3. `arch/riscv/kernel/irq_pipeline.c`
4. `arch/riscv/kernel/traps.c`
5. `arch/riscv/kernel/smp.c`
6. `arch/riscv/include/asm/mmu_context.h`

Together they cover the same subjects called out by the public upstream patch
series:

- IRQ state semantics
- trap routing
- out-of-band IPI delivery
- dovetail-aware MM switching

### 3. Two EVL arch files are still explicit placeholders

The following files should currently be treated as build enablers, not complete
runtime support:

- `arch/riscv/include/asm/evl/fptest.h`
- `arch/riscv/include/uapi/asm/evl/fptest.h`

This is especially important because public EVL platform notes repeatedly show
FPU handling as a common source of incomplete stress validation.

### 4. `asm/dovetail.h` and `asm/mmu_context.h` are still provisional

`arch/riscv/include/asm/dovetail.h` currently contains stubbed
`arch_dovetail_switch_*()` hooks.

`arch/riscv/include/asm/mmu_context.h` currently implements:

```c
switch_oob_mm(prev, next, task) { switch_mm(prev, next, task); }
```

That may be sufficient for early build progress, but it should not be assumed
to be the final `RISC-V`-correct behavior until we align it with the intended
upstream `dovetail-aware memory management` design.

## Priority Order for Future Work

### Priority 1: architecture semantics

Audit and refine:

- `include/asm/irqflags.h`
- `include/asm/irq_pipeline.h`
- `kernel/irq_pipeline.c`
- `kernel/traps.c`
- `kernel/smp.c`
- `include/asm/mmu_context.h`

### Priority 2: scheduler hand-off contract

Audit interactions with:

- `include/linux/dovetail.h`
- `kernel/dovetail.c`
- `kernel/sched/core.c`

This is where the current build has already shown unresolved coupling.

### Priority 3: EVL arch completion

Replace placeholders for:

- `include/asm/evl/fptest.h`
- `include/uapi/asm/evl/fptest.h`
- `include/asm/evl/calibration.h`

These matter less for initial linking than IRQ/MM/scheduler correctness, but
they matter for real validation.

## Practical Guidance

When touching `arch/riscv/` from now on:

- prefer keeping bridge files simple
- prefer reducing local semantic inventions in high-risk files
- treat any change to IRQ, trap, MM, or scheduler code as design work, not
  just compilation work
