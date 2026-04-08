// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2024 - RISC-V Dovetail/EVL IRQ pipeline arch hooks
 * Ported from arch/arm64/kernel/irq_pipeline.c
 */
#include <linux/cpuidle.h>
#include <linux/irq.h>
#include <linux/irqdesc.h>
#include <linux/irq_pipeline.h>

/*
 * arch_do_IRQ_pipelined - replay a deferred inband IRQ
 *
 * Called from do_inband_irq() in kernel/irq/pipeline.c with:
 *   - hard IRQs ON on entry
 *   - inband stage stalled (software IRQ lock held)
 *
 * This is NOT a real hardware interrupt entry — it is a software replay
 * of an interrupt that was previously logged in the inband stage queue.
 * RCU is already watching (we are executing in task/softirq context),
 * so we must use irq_enter_rcu()/irq_exit_rcu() rather than
 * irq_enter()/irq_exit(). The latter calls ct_irq_enter() which would
 * wrongly tell RCU that we are entering a hardware interrupt from an
 * idle/user context, corrupting the RCU state machine and causing
 * stalls or hangs.
 *
 * On RISC-V, replaying the local timer IRQ with hard IRQs left enabled
 * allows a fresh hardware timer interrupt to nest over the replayed
 * handler, which immediately re-defers the same virq and keeps the
 * descriptor stuck in a self-sustaining deferred/replay loop. We
 * therefore mask hard IRQ delivery locally for the duration of the
 * replayed generic irq core dispatch, restoring the previous hardware
 * state afterwards. The inband stage remains stalled throughout, so we
 * are only preventing unwanted hardware re-entry while consuming an
 * already deferred event.
 */
void arch_do_IRQ_pipelined(struct irq_desc *desc)
{
	struct pt_regs *regs = raw_cpu_ptr(&irq_pipeline.tick_regs);
	struct pt_regs *old_regs = set_irq_regs(regs);
	unsigned long flags;
	unsigned int irq = irq_desc_get_irq(desc);

	flags = hard_local_irq_save();
	irq_enter_rcu();
	/*
	 * Replay deferred in-band IRQs through the generic IRQ entry point
	 * rather than invoking the descriptor handler directly, keeping the
	 * dispatch on the generic irq core path.
	 */
	generic_handle_irq(irq);
	irq_exit_rcu();
	hard_local_irq_restore(flags);

	set_irq_regs(old_regs);
}

void __init arch_irq_pipeline_init(void)
{
	/* no per-arch init needed for RISC-V */
}

#if defined(CONFIG_IRQ_PIPELINE) && !defined(CONFIG_EVL)
bool irq_cpuidle_control(struct cpuidle_device *dev,
			 struct cpuidle_state *state)
{
	/*
	 * RISC-V IRQ pipeline bring-up is not stable across the generic
	 * cpuidle path yet: on QEMU virt, enabling cpuidle under a
	 * pipelined kernel resets before the first Linux printk, while the
	 * matching noidle build reaches the kernel banner. Until the arch
	 * idle/trap glue is made pipeline-aware, keep cpuidle disabled for
	 * plain IRQ_PIPELINE configurations so that boot behavior matches the
	 * validated noidle baseline.
	 */
	return false;
}
#endif
