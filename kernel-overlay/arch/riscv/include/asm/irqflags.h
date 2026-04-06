/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2012 Regents of the University of California
 *
 * EVL/Dovetail IRQ pipeline support for RISC-V.
 *
 * This file defines ONLY native_*() hardware operations (direct SR_IE CSR
 * manipulation).  It does NOT define arch_local_*() — those are defined in
 * asm/irq_pipeline.h with two behaviours:
 *
 *   CONFIG_IRQ_PIPELINE=y:
 *     arch_local_*() → stall-bit virtualisation (inband_irq_*())
 *     Hardware SR_IE is managed exclusively by the pipeline core.
 *
 *   CONFIG_IRQ_PIPELINE=n:
 *     arch_local_*() → native_*() → direct SR_IE hardware manipulation.
 *
 * Rationale for NOT defining arch_local_*() here:
 *   After arch_irq_pipeline_init() the pipeline owns SR_IE.  If in-band
 *   code calls arch_local_irq_enable() and that directly sets SR_IE, it
 *   races with the OOB stage's control of SR_IE → timer/tick corruption →
 *   boot hang.  The correct Dovetail design (ARM64 reference) is:
 *     asm/irqflags.h  → native_*()  (hardware)
 *     asm/irq_pipeline.h → arch_local_*() (stall-bit when pipelined)
 *
 * asm/irq_pipeline.h is included automatically via linux/irqflags.h →
 * linux/irq_pipeline.h → asm/irq_pipeline.h, so consumers do not need to
 * include it explicitly.
 */

#ifndef _ASM_RISCV_IRQFLAGS_H
#define _ASM_RISCV_IRQFLAGS_H

#include <asm/processor.h>
#include <asm/csr.h>

/* -----------------------------------------------------------------------
 * Hardware (native) IRQ operations.
 * These always manipulate the real SR_IE bit in sstatus.
 * Required by asm-generic/irq_pipeline.h (hard_*() macros → native_*()).
 * Also used directly by arch_local_*() when !CONFIG_IRQ_PIPELINE.
 * ----------------------------------------------------------------------- */

static inline unsigned long native_save_flags(void)
{
	/*
	 * Dovetail only needs the hardware interrupt-enable state here.
	 * Keeping unrelated sstatus bits out of the saved flags matches the
	 * upstream RISC-V bring-up direction and avoids feeding mixed flag
	 * values back into irq-pipeline state helpers.
	 */
	return csr_read(CSR_STATUS) & SR_IE;
}

static inline void native_irq_enable(void)
{
	csr_set(CSR_STATUS, SR_IE);
}

static inline void native_irq_disable(void)
{
	csr_clear(CSR_STATUS, SR_IE);
}

static inline unsigned long native_irq_save(void)
{
	return csr_read_clear(CSR_STATUS, SR_IE) & SR_IE;
}

static inline int native_irqs_disabled_flags(unsigned long flags)
{
	return !(flags & SR_IE);
}

static inline int native_irqs_disabled(void)
{
	return native_irqs_disabled_flags(native_save_flags());
}

static inline void native_irq_restore(unsigned long flags)
{
	if (flags & SR_IE)
		csr_set(CSR_STATUS, SR_IE);
	else
		csr_clear(CSR_STATUS, SR_IE);
}

static inline void native_irq_sync(void)
{
	unsigned long flags = native_irq_save();

	/*
	 * Create a short hard-IRQ window, then restore the exact previous
	 * hardware IRQ state instead of unconditionally leaving interrupts
	 * disabled.
	 */
	native_irq_enable();
	native_irq_restore(flags);
}

/*
 * arch_local_*() and arch_irqs_disabled_flags() are defined in
 * asm/irq_pipeline.h.  Include it here so that any file doing
 * #include <asm/irqflags.h> directly (not via linux/irqflags.h) also
 * gets the correct arch_local_*() definitions.
 *
 * Header guards in irq_pipeline.h prevent circular include issues:
 *   irqflags.h defines native_*() → includes irq_pipeline.h
 *   irq_pipeline.h includes irqflags.h (already guarded, skipped) → defines arch_local_*()
 */
#include <asm/irq_pipeline.h>

#endif /* _ASM_RISCV_IRQFLAGS_H */
