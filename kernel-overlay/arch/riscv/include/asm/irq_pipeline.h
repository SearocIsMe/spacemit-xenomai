/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RISC-V IRQ pipeline (Dovetail) arch hooks.
 *
 * Ported from arch/arm64/include/asm/irq_pipeline.h
 * Copyright (C) 2018 Philippe Gerum <rpm@xenomai.org>
 *
 * RISC-V adaptation for SpacemiT K1 (2026).
 *
 * This file defines arch_local_*() for both CONFIG_IRQ_PIPELINE and
 * !CONFIG_IRQ_PIPELINE.  native_*() hardware ops are defined in
 * asm/irqflags.h which is included below.
 *
 * Design:
 *
 *   CONFIG_IRQ_PIPELINE=y:
 *     arch_local_*() → inband_irq_*() — stall-bit virtualisation.
 *     Hardware SR_IE is managed by the pipeline core, NOT in-band code.
 *
 *   CONFIG_IRQ_PIPELINE=n:
 *     arch_local_*() → native_*() — direct SR_IE CSR manipulation.
 *
 * RISC-V trap-entry SR_IE vs SR_PIE note:
 *   On RISC-V, hardware clears sstatus.SIE and copies its old value to
 *   sstatus.SPIE on every trap entry.  As a result regs->status & SR_IE
 *   is ALWAYS 0 in a trap frame.  arch_steal_pipelined_tick() must check
 *   SR_PIE (the pre-trap value) — NOT SR_IE — to determine whether in-band
 *   IRQs were enabled before the tick fired.  Using SR_IE here causes every
 *   tick to be stolen by the OOB stage, jiffies never advance, and the
 *   system hangs at the splash screen (fixed Apr 2026).
 */
#ifndef _ASM_RISCV_IRQ_PIPELINE_H
#define _ASM_RISCV_IRQ_PIPELINE_H

#include <asm-generic/irq_pipeline.h>

#ifdef CONFIG_IRQ_PIPELINE

#include <asm/csr.h>
#include <asm/evl_debug.h>
#include <asm/irqflags.h>

/*
 * RISC-V uses the SR_IE bit in sstatus for hardware IRQ masking.
 * The pipeline virtualises this: in-band callers should only observe a
 * simple virtual enabled/disabled state, while the pipeline core still
 * needs helpers to merge/split that virtual state with the real SR_IE bit.
 *
 * IRQMASK_i_POS: synthetic bit position of the virtual stall flag.
 * IRQMASK_I_POS: synthetic/native position corresponding to SR_IE.
 */
#define IRQMASK_i_POS		0	/* virtual stall flag bit */
#define IRQMASK_I_POS		1	/* SR_IE position in sstatus */
#define IRQMASK_I_BIT		SR_IE

static inline notrace
unsigned long arch_irqs_virtual_to_native_flags(int stalled)
{
	/*
	 * Convert the virtual in-band state carried in the synthetic low bit
	 * to the native SR_IE convention used by hard_local_*() helpers:
	 *   stalled=0 -> SR_IE set   (enabled)
	 *   stalled=1 -> SR_IE clear (disabled)
	 */
	return (!stalled) ? SR_IE : 0UL;
}

static inline notrace
unsigned long arch_irqs_native_to_virtual_flags(unsigned long flags)
{
	/*
	 * Convert the native SR_IE state into the synthetic one-bit virtual
	 * state used by the generic pipeline helpers.
	 */
	return (!(flags & SR_IE)) ? (1UL << IRQMASK_i_POS) : 0UL;
}

/*
 * arch_local_*(): in-band IRQ state management via stall-bit.
 * After arch_irq_pipeline_init(), the pipeline owns hardware SR_IE.
 * In-band code must ONLY touch the stall flag, not SR_IE directly.
 */
static inline notrace unsigned long arch_local_irq_save(void)
{
	unsigned long stalled = inband_irq_save();

	barrier();
	return stalled ? 1UL : 0UL;
}

static inline notrace void arch_local_irq_enable(void)
{
	barrier();
	inband_irq_enable();
}

static inline notrace void arch_local_irq_disable(void)
{
	inband_irq_disable();
	barrier();
}

static inline notrace unsigned long arch_local_save_flags(void)
{
	unsigned long stalled = inband_irqs_disabled();

	barrier();
	return stalled ? 1UL : 0UL;
}

static inline int arch_irqs_disabled_flags(unsigned long flags)
{
	return !!flags;
}

static inline notrace void arch_local_irq_restore(unsigned long flags)
{
	inband_irq_restore(arch_irqs_disabled_flags(flags) ? 1 : 0);
	barrier();
}

static inline void arch_save_timer_regs(struct pt_regs *dst,
					struct pt_regs *src)
{
	dst->status = src->status;
	dst->epc    = src->epc;
}

static inline bool arch_steal_pipelined_tick(struct pt_regs *regs)
{
	/*
	 * On RISC-V, the hardware atomically copies sstatus.SIE → sstatus.SPIE
	 * and clears sstatus.SIE on trap entry.  Therefore regs->status & SR_IE
	 * (= SR_SIE) is ALWAYS 0 in the trap frame — checking it would steal
	 * every tick and starve in-band Linux of timer interrupts (boot hangs
	 * at Bianbu splash, jiffies frozen).
	 *
	 * The correct check is SR_PIE (= SR_SPIE in S-mode), which holds the
	 * pre-trap SIE value:
	 *   SR_PIE == 0  → IRQs were disabled when the tick fired → steal.
	 *   SR_PIE == 1  → IRQs were enabled → deliver to in-band Linux.
	 *
	 * This matches the ARM64 reference (PSR_I_BIT is NOT cleared on exception
	 * entry on ARM64, so arm64 can use the I-bit directly; RISC-V must use
	 * SR_PIE instead).
	 */
	return !(regs->status & SR_PIE);
}

static inline int arch_enable_oob_stage(void)
{
	return 0;
}

extern void (*handle_arch_irq)(struct pt_regs *);

static inline void arch_handle_irq_pipelined(struct pt_regs *regs)
{
	static bool trace_arch_irq_seen;
	static bool trace_arch_irq_returned;

	if (!trace_arch_irq_seen) {
		trace_arch_irq_seen = true;
		riscv_evl_trace("EVLDBG arch_handle_irq_pipelined entry\n");
		riscv_evl_trace_ulong("EVLDBG arch_handle_irq_pipelined fn=",
				      (unsigned long)handle_arch_irq);
	}

	handle_arch_irq(regs);

	if (!trace_arch_irq_returned) {
		trace_arch_irq_returned = true;
		riscv_evl_trace("EVLDBG arch_handle_irq_pipelined return\n");
	}
}

#define arch_kentry_get_irqstate(__regs)	0
#define arch_kentry_set_irqstate(__regs, __irqstate)	\
	do { (void)(__irqstate); } while (0)

/*
 * Out-of-band IPI assignments for RISC-V.
 * ipi_irq_base is set during SMP init; OOB IPIs are offset from it.
 */
#define OOB_NR_IPI		3
#define OOB_IPI_OFFSET		1
extern int ipi_irq_base;
#define TIMER_OOB_IPI		(ipi_irq_base + OOB_IPI_OFFSET)
#define RESCHEDULE_OOB_IPI	(TIMER_OOB_IPI + 1)
#define CALL_FUNCTION_OOB_IPI	(RESCHEDULE_OOB_IPI + 1)

#else  /* !CONFIG_IRQ_PIPELINE */

#include <asm/irqflags.h>

/*
 * arch_local_*(): without IRQ pipeline, map directly to hardware ops.
 */
static inline unsigned long arch_local_irq_save(void)
{
	return native_irq_save();
}

static inline void arch_local_irq_enable(void)
{
	native_irq_enable();
}

static inline void arch_local_irq_disable(void)
{
	native_irq_disable();
}

static inline unsigned long arch_local_save_flags(void)
{
	return native_save_flags();
}

static inline void arch_local_irq_restore(unsigned long flags)
{
	native_irq_restore(flags);
}

static inline int arch_irqs_disabled_flags(unsigned long flags)
{
	return native_irqs_disabled_flags(flags);
}

#endif /* !CONFIG_IRQ_PIPELINE */

static inline int arch_irqs_disabled(void)
{
	return arch_irqs_disabled_flags(arch_local_save_flags());
}

#endif /* _ASM_RISCV_IRQ_PIPELINE_H */
