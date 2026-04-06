// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2024 - RISC-V Dovetail/EVL IRQ pipeline arch hooks
 * Ported from arch/arm64/kernel/irq_pipeline.c
 */
#include <linux/irq.h>
#include <linux/irq_pipeline.h>

/*
 * arch_do_IRQ_pipelined - replay a deferred inband IRQ
 *
 * Called from do_inband_irq() in kernel/irq/pipeline.c with:
 *   - hard IRQs ON (hardware interrupt delivery enabled)
 *   - inband stage stalled (software IRQ lock held)
 *
 * This is NOT a real hardware interrupt entry — it is a software replay
 * of an interrupt that was previously logged in the inband stage queue.
 * RCU is already watching (we are executing in task/softirq context),
 * so we must use irq_enter_rcu()/irq_exit_rcu() rather than
 * irq_enter()/irq_exit().  The latter calls ct_irq_enter() which would
 * wrongly tell RCU that we are entering a hardware interrupt from an
 * idle/user context, corrupting the RCU state machine and causing
 * stalls or hangs.
 */
void arch_do_IRQ_pipelined(struct irq_desc *desc)
{
	struct pt_regs *regs = raw_cpu_ptr(&irq_pipeline.tick_regs);
	struct pt_regs *old_regs = set_irq_regs(regs);

	irq_enter_rcu();
	handle_irq_desc(desc);
	irq_exit_rcu();

	set_irq_regs(old_regs);
}

void __init arch_irq_pipeline_init(void)
{
	/* no per-arch init needed for RISC-V */
}
