/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2012 Regents of the University of California
 *
 * EVL/Dovetail IRQ pipeline support:
 * Defines native_*() hardware operations.  arch_local_*() are defined in
 * asm/irq_pipeline.h which is included at the bottom of this file.
 *
 * With CONFIG_IRQ_PIPELINE:
 *   arch_local_*() → stall-bit virtualisation (inband_irq_*())
 *   native_*() / hard_*() → direct SR_IE hardware manipulation
 *
 * Without CONFIG_IRQ_PIPELINE:
 *   arch_local_*() → native_*() → direct SR_IE hardware manipulation
 *
 * The arch_irq_pipeline_init() hook MUST call hard_local_irq_enable()
 * so that hardware SR_IE=1 before the first local_irq_enable() fires
 * through the pipeline.  Without this, inband_irq_enable() would save
 * SR_IE=0 and never restore it to 1, hanging the boot.
 */

#ifndef _ASM_RISCV_IRQFLAGS_H
#define _ASM_RISCV_IRQFLAGS_H

#include <asm/processor.h>
#include <asm/csr.h>

/* -----------------------------------------------------------------------
 * Hardware (native) IRQ operations.
 * These always manipulate the real SR_IE bit in sstatus.
 * Required by asm-generic/irq_pipeline.h (hard_*() macros → native_*()).
 * ----------------------------------------------------------------------- */

static inline unsigned long native_save_flags(void)
{
	return csr_read(CSR_STATUS);
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
	return csr_read_clear(CSR_STATUS, SR_IE);
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
	csr_set(CSR_STATUS, flags & SR_IE);
}

static inline void native_irq_sync(void)
{
	native_irq_enable();
	native_irq_disable();
}

/* -----------------------------------------------------------------------
 * arch_local_*() — used by generic kernel code.
 * These always map to native_*() (direct hardware SR_IE manipulation).
 *
 * The IRQ pipeline core uses hard_*() / inband_irq_*() / oob_irq_*()
 * directly and does NOT rely on arch_local_*() being virtualised.
 *
 * DO NOT include asm/irq_pipeline.h here: doing so would override
 * arch_local_*() with stall-bit-only ops that never set hardware SR_IE,
 * causing a boot hang (no timer interrupts fire before pipeline init).
 * ----------------------------------------------------------------------- */

static inline unsigned long arch_local_save_flags(void)
{
	return native_save_flags();
}

static inline void arch_local_irq_enable(void)
{
	native_irq_enable();
}

static inline void arch_local_irq_disable(void)
{
	native_irq_disable();
}

static inline unsigned long arch_local_irq_save(void)
{
	return native_irq_save();
}

static inline int arch_irqs_disabled_flags(unsigned long flags)
{
	return native_irqs_disabled_flags(flags);
}

static inline int arch_irqs_disabled(void)
{
	return arch_irqs_disabled_flags(arch_local_save_flags());
}

static inline void arch_local_irq_restore(unsigned long flags)
{
	native_irq_restore(flags);
}

#endif /* _ASM_RISCV_IRQFLAGS_H */
