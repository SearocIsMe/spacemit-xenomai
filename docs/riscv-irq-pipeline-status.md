# RISC-V IRQ pipeline status

## Main fix

The primary boot failure was traced to `riscv_v_context_nesting_end()`.

Before the fix, that path checked virtual in-band IRQ state via
`inband_irqs_disabled()`. On the IRQ pipeline return path this could be false
even while hard IRQs were still correctly disabled, which triggered a WARN and
sent execution into:

- `report_bug()`
- `__warn()`
- `_printk()`
- `vprintk_emit()`

The WARN printing path then reliably exposed the secondary stack corruption
symptom.

The fix is:

- commit `75bef2e`
- `riscv: check hard irqs in vector nesting end`

It changes the check in
[kernel_mode_vector.c](/home/jhp17/spacemit-xenomai/kernel-overlay/arch/riscv/kernel/kernel_mode_vector.c)
from virtual IRQ state to hard IRQ state.

## Validation

After `75bef2e`:

- `kdevtmpfs` starts successfully
- `kworker_u` starts successfully
- the earlier `report_bug() -> __warn() -> vprintk()` chain is no longer the
  dominant stop point

Natural boot validation now succeeds much further than before:

- no `handle_bad_stack`
- no `Invalid read at addr 0xFFC`
- verified on long no-GDB runs

## Secondary issue

The remaining reproducible `Invalid read at addr 0xFFC` issue is now isolated
to the debug startup mode:

- problematic: `-S + gdb continue`
- stable: normal boot
- stable: GDB stub enabled without reset stop

This means the remaining issue is no longer the primary kernel boot blocker.

## Recommended debug workflow

Prefer:

- [run-irq-pipeline-preserve.sh](/home/jhp17/spacemit-xenomai/scripts/qemu/run-irq-pipeline-preserve.sh)

This now defaults to:

- GDB stub enabled
- no reset-stop

If a stopped-at-reset workflow is ever needed again, set:

```bash
QEMU_GDB_STOP=1 bash scripts/qemu/run-irq-pipeline-preserve.sh \
  .build/qemu-virt/irq-pipeline custom-run
```

## Current status

- primary boot blocker: fixed
- natural boot: stable enough for continued bring-up
- `-S + gdb continue` path: still a secondary debug-only issue
