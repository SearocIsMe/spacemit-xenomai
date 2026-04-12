# QEMU `virt` Validation Lane for RISC-V EVL Bring-up

This document adds a PC-side validation lane for the standard `riscv64` QEMU
`virt` machine. The goal is not to emulate the Milk-V Jupiter SD-card boot
chain. The goal is to answer a narrower question:

Can the current kernel tree bring up generic `RISC-V + IRQ_PIPELINE +
DOVETAIL + EVL` at all, before we spend more SD-card cycles on board-specific
debugging?

## What This Lane Can and Cannot Tell Us

Useful:

- whether the generic `RISC-V` kernel still configures and links for:
  - `IRQ_PIPELINE`
  - `DOVETAIL`
  - `EVL`
- whether the resulting kernel reaches early boot on a standard `virt` machine
- whether failures are already visible before any SpacemiT-specific drivers or
  Jupiter boot files are involved

Not useful:

- validating Jupiter's SPL/U-Boot/raw-sector boot chain
- validating `extlinux.conf`, `env_k1-x.txt`, or the vendor SD partitioning
- reproducing SpacemiT K1 clock, interrupt, PM, MMC, or display driver issues

Treat this as an architecture smoke test lane, not as a substitute for UART on
real hardware.

## Files Added for This Lane

- [`configs/qemu_virt_evl_defconfig`](/home/jhp17/spacemit-xenomai/configs/qemu_virt_evl_defconfig)
- [`scripts/build/build-qemu-virt-bisect.sh`](/home/jhp17/spacemit-xenomai/scripts/build/build-qemu-virt-bisect.sh)
- [`scripts/qemu/setup-qemu-riscv64-ubuntu.sh`](/home/jhp17/spacemit-xenomai/scripts/qemu/setup-qemu-riscv64-ubuntu.sh)
- [`scripts/qemu/run-riscv64-virt.sh`](/home/jhp17/spacemit-xenomai/scripts/qemu/run-riscv64-virt.sh)

## Host Setup on Ubuntu 24.04

Install the host QEMU packages with:

```bash
bash scripts/qemu/setup-qemu-riscv64-ubuntu.sh
```

This script installs:

- `qemu-system-misc`
- `qemu-utils`

Why these packages:

- `qemu-system-misc` provides `qemu-system-riscv64` on Ubuntu
- `qemu-utils` is useful for raw image handling and format conversion

Quick verification:

```bash
command -v qemu-system-riscv64
qemu-system-riscv64 --version
```

If you prefer manual installation:

```bash
sudo apt-get update
sudo apt-get install -y qemu-system-misc qemu-utils
```

## Build Matrix

The QEMU lane mirrors the staged Jupiter lane, but swaps the board-specific
base defconfig for generic `RISC-V defconfig`.

| Variant | Purpose |
|---------|---------|
| `vanilla-qemu` | Generic RISC-V baseline without EVL/Dovetail |
| `irq-pipeline-qemu` | Check whether IRQ pipeline hooks still configure, build, and reach boot |
| `irq-pipeline-pmoff-qemu` | Same as above, but removes PM and SBI cpuidle first |
| `irq-pipeline-tickoff-qemu` | Same as above, but keeps CPU idle while removing tickless and broadcast behavior |
| `irq-pipeline-nosmp-qemu` | Same as above, but removes SMP from the equation |
| `irq-pipeline-noidle-qemu` | Same as above, but with idle-related tweaks |
| `irq-pipeline-minimal-qemu` | Smallest practical IRQ pipeline debugging slice |
| `dovetail-qemu` | Add Dovetail on top of IRQ pipeline |
| `dovetail-noidle-qemu` | Add Dovetail on top of the noidle slice |
| `dovetail-nosmp-qemu` | Add Dovetail on top of the nosmp/noidle slice |
| `full-evl-qemu` | Add EVL core on top of Dovetail |

Build all variants:

```bash
bash scripts/build/build-qemu-virt-bisect.sh all
```

Build a single variant:

```bash
bash scripts/build/build-qemu-virt-bisect.sh irq-pipeline-qemu
```

## Running a Built Kernel

The runner expects a build directory produced by the script above.

Example:

```bash
bash scripts/qemu/run-riscv64-virt.sh \
  .build/qemu-virt/irq-pipeline
```

If you have an initramfs:

```bash
INITRD=/path/to/rootfs.cpio.gz \
  bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/full-evl
```

If you have a raw rootfs image:

```bash
ROOTFS_IMG=/path/to/rootfs.img \
  bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/full-evl
```

Useful optional toggles:

```bash
QEMU_NET=1 QEMU_SMP=2 QEMU_MEM=1024 \
  APPEND="init=/bin/sh" \
  bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/vanilla
```

For early reset loops, stop after the first guest reset and keep a QEMU-side
trace:

```bash
QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.qemu.log \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

To get very-early RISC-V IRQ pipeline trace markers on the console, append
`evl_debug` to the kernel command line:

```bash
QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.qemu.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

`QEMU_DEBUG_LOG` only stores QEMU's internal debug trace. To capture the guest
console itself, including `EVLDBG`, mirror stdout to a second file:

```bash
QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.evl_debug.qemu.log \
QEMU_STDOUT_LOG=.build/qemu-virt/output.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

Current markers are intentionally one-shot and focus on the shortest suspect
path:

- `EVLDBG do_irq entry`
- `EVLDBG do_irq pipelined`
- `EVLDBG handle_riscv_irq entry`
- `EVLDBG handle_riscv_irq pipelined`
- `EVLDBG riscv_intc_irq entry`

You can also try single-core mode to rule out SMP effects:

```bash
QEMU_NO_REBOOT=1 QEMU_SMP=1 \
  bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

## How to Use This Alongside Jupiter Testing

Recommended order:

1. `vanilla-qemu`
2. `irq-pipeline-qemu`
3. `irq-pipeline-pmoff-qemu`
4. `irq-pipeline-tickoff-qemu`
5. `irq-pipeline-nosmp-qemu`
6. `irq-pipeline-noidle-qemu`
7. `irq-pipeline-minimal-qemu`
8. `dovetail-qemu`
9. `dovetail-noidle-qemu`
10. `dovetail-nosmp-qemu`
11. `full-evl-qemu`
12. Only then spend another SD-card cycle on the corresponding Jupiter stage

Interpretation:

- If `vanilla-qemu` fails, the issue is too fundamental for board testing.
- If `vanilla-qemu` boots but `irq-pipeline-qemu` fails, the blocker is likely
  in the generic RISC-V IRQ pipeline path.
- If `irq-pipeline-qemu` works but Jupiter still hangs at the same stage, that
  points more strongly at SpacemiT-specific interrupt, timer, boot, or module
  interactions.
- If `full-evl-qemu` reaches boot but `full-evl` on Jupiter does not, the
  remaining blocker is probably not in EVL core wiring alone.

If `irq-pipeline-qemu` resets back to OpenSBI before any Linux banner appears,
that points to a very early failure in the generic RISC-V bring-up path,
typically before normal console output is available.

If `irq-pipeline-qemu` resets but `irq-pipeline-noidle-qemu` or
`irq-pipeline-pmoff-qemu` does not, prioritize the idle / PM / SBI cpuidle
interaction over the core IRQ pipeline wiring itself.

## Practical Notes

- `QEMU virt` uses a generic machine model, not the SpacemiT K1 device tree.
- The script prefers an explicit `QEMU_BIOS` path when provided, and otherwise
  auto-detects the standard host OpenSBI firmware before falling back to
  `-bios default`.
- For reproducibility, `QEMU_BOOT_HART=<n>` patches a generated DTB with
  `/chosen/boot-hartid = <n>` and passes it back to QEMU via `-dtb`.
- For the first smoke test, an initramfs is optional. Even an early boot panic
  can still be useful if it proves the kernel reaches the expected stage.
- This lane is intentionally isolated from the SD-card image generation
  scripts so it cannot accidentally change the Jupiter flashing workflow.
