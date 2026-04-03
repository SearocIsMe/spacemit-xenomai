/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RISC-V IRQ pipeline (Dovetail) arch hooks.
 *
 * Ported from arch/arm64/include/asm/irq_pipeline.h
 * Copyright (C) 2018 Philippe Gerum <rpm@xenomai.org>
 *
 * RISC-V adaptation for SpacemiT K1 (2026).
 *
 * This file is included at the bottom of asm/irqflags.h (after native_*
 * are defined), so it may safely reference them.
 *
 * arch_*() are defined here for both CONFIG_IRQ_PIPELINE and !CONFIG_IRQ_PIPELINE.
 */
#ifndef _ASM_RISCV_IRQ_PIPELINE_H
#define _ASM_RISCV_IRQ_PIPELINE_H

#include <asm-generic/irq_pipeline.h>

#ifdef CONFIG_IRQ_PIPELINE

#include <asm/csr.h>

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

/*
 * RISC-V uses the SR_IE bit in sstatus for hardware IRQ masking.
 * The pipeline virtualises this: the "virtual" IRQ state is the
 * software stall flag; the "native" state is the actual SR_IE bit.
 *
 * IRQMASK_i_POS: bit position of the virtual (software) stall flag.
 * IRQMASK_I_POS: bit position of the native SR_IE hardware flag.
 */
#define IRQMASK_i_POS		0	/* virtual stall flag bit */
#define IRQMASK_I_POS		1	/* SR_IE position in sstatus */
#define IRQMASK_I_BIT		SR_IE

static inline notrace
unsigned long arch_irqs_virtual_to_native_flags(int stalled)
{
	/*
	 * stalled=1 → IRQs disabled → SR_IE should be 0.
	 * Return SR_IE set only when NOT stalled (IRQs enabled).
	 */
	return (!stalled) ? SR_IE : 0UL;
}

static inline notrace
unsigned long arch_irqs_native_to_virtual_flags(unsigned long flags)
{
	/*
	 * SR_IE=0 → IRQs disabled → stalled=1.
	 */
	return (!(flags & SR_IE)) ? (1UL << IRQMASK_i_POS) : 0UL;
}

static inline void arch_save_timer_regs(struct pt_regs *dst,
					struct pt_regs *src)
{
	dst->status = src->status;
	dst->epc    = src->epc;
}

static inline bool arch_steal_pipelined_tick(struct pt_regs *regs)
{
	/* SR_IE clear means IRQs were disabled when the tick fired */
	return !(regs->status & SR_IE);
}

static inline int arch_enable_oob_stage(void)
{
	return 0;
}

extern void (*handle_arch_irq)(struct pt_regs *);

static inline void arch_handle_irq_pipelined(struct pt_regs *regs)
{
	handle_arch_irq(regs);
}

#define arch_kentry_get_irqstate(__regs)	0
#define arch_kentry_set_irqstate(__regs, __irqstate)	\
	do { (void)(__irqstate); } while (0)

#endif /* !CONFIG_IRQ_PIPELINE */

#endif /* _ASM_RISCV_IRQ_PIPELINE_H */
