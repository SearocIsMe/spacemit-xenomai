// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (C) 2012 ARM Ltd.
 * Author: Catalin Marinas <catalin.marinas@arm.com>
 * Copyright (C) 2017 Linaro Ltd. <ard.biesheuvel@linaro.org>
 * Copyright (C) 2021 SiFive
 */
#include <linux/compiler.h>
#include <linux/irqflags.h>
#include <linux/percpu.h>
#include <linux/preempt.h>
#include <linux/types.h>

#include <asm/vector.h>
#include <asm/switch_to.h>
#include <asm/simd.h>
#ifdef CONFIG_RISCV_ISA_V_PREEMPTIVE
#include <asm/asm-prototypes.h>
#endif
#include <asm/evl_debug.h>

static inline void riscv_v_flags_set(u32 flags)
{
	WRITE_ONCE(current->thread.riscv_v_flags, flags);
}

static inline void riscv_v_start(u32 flags)
{
	int orig;

	orig = riscv_v_flags();
	BUG_ON((orig & flags) != 0);
	riscv_v_flags_set(orig | flags);
	barrier();
}

static inline void riscv_v_stop(u32 flags)
{
	int orig;

	barrier();
	orig = riscv_v_flags();
	BUG_ON((orig & flags) == 0);
	riscv_v_flags_set(orig & ~flags);
}

void get_cpu_vector_context(void)
{
	if (!IS_ENABLED(CONFIG_PREEMPT_RT))
		local_bh_disable();
	else
		preempt_disable();

	riscv_v_start(RISCV_KERNEL_MODE_V);
}

void put_cpu_vector_context(void)
{
	riscv_v_stop(RISCV_KERNEL_MODE_V);

	if (!IS_ENABLED(CONFIG_PREEMPT_RT))
		local_bh_enable();
	else
		preempt_enable();
}

#ifdef CONFIG_RISCV_ISA_V_PREEMPTIVE
static __always_inline u32 *riscv_v_flags_ptr(void)
{
	return &current->thread.riscv_v_flags;
}

static inline void riscv_preempt_v_set_dirty(void)
{
	*riscv_v_flags_ptr() |= RISCV_PREEMPT_V_DIRTY;
}

static inline void riscv_preempt_v_reset_flags(void)
{
	*riscv_v_flags_ptr() &= ~(RISCV_PREEMPT_V_DIRTY | RISCV_PREEMPT_V_NEED_RESTORE);
}

static inline void riscv_v_ctx_depth_inc(void)
{
	*riscv_v_flags_ptr() += RISCV_V_CTX_UNIT_DEPTH;
}

static inline void riscv_v_ctx_depth_dec(void)
{
	*riscv_v_flags_ptr() -= RISCV_V_CTX_UNIT_DEPTH;
}

static inline u32 riscv_v_ctx_get_depth(void)
{
	return *riscv_v_flags_ptr() & RISCV_V_CTX_DEPTH_MASK;
}

static int riscv_v_stop_kernel_context(void)
{
	if (riscv_v_ctx_get_depth() != 0 || !riscv_preempt_v_started(current))
		return 1;

	riscv_preempt_v_clear_dirty(current);
	riscv_v_stop(RISCV_PREEMPT_V);
	return 0;
}

static int riscv_v_start_kernel_context(bool *is_nested)
{
	struct __riscv_v_ext_state *kvstate, *uvstate;

	kvstate = &current->thread.kernel_vstate;
	if (!kvstate->datap)
		return -ENOENT;

	if (riscv_preempt_v_started(current)) {
		WARN_ON(riscv_v_ctx_get_depth() == 0);
		*is_nested = true;
		get_cpu_vector_context();
		if (riscv_preempt_v_dirty(current)) {
			__riscv_v_vstate_save(kvstate, kvstate->datap);
			riscv_preempt_v_clear_dirty(current);
		}
		riscv_preempt_v_set_restore(current);
		return 0;
	}

	riscv_v_start(RISCV_PREEMPT_V | RISCV_PREEMPT_V_DIRTY);
	if ((task_pt_regs(current)->status & SR_VS) == SR_VS_DIRTY) {
		uvstate = &current->thread.vstate;
		__riscv_v_vstate_save(uvstate, uvstate->datap);
	}
	riscv_preempt_v_clear_dirty(current);
	return 0;
}

asmlinkage void riscv_v_context_nesting_start(struct pt_regs *regs)
{
	int depth;

	if (!riscv_preempt_v_started(current))
		return;

	depth = riscv_v_ctx_get_depth();
	if (depth == 0 && (regs->status & SR_VS) == SR_VS_DIRTY)
		riscv_preempt_v_set_dirty();

	riscv_v_ctx_depth_inc();
}

asmlinkage void riscv_v_context_nesting_end(struct pt_regs *regs)
{
	struct __riscv_v_ext_state *vstate = &current->thread.kernel_vstate;
	u32 depth;

	WARN_ON(!irqs_disabled());

	if (riscv_evl_trace_enabled()) {
		riscv_evl_trace_hex("EVLDBG riscv_v_context_nesting_end cpu=",
				    raw_smp_processor_id());
		riscv_evl_trace_ptr("EVLDBG riscv_v_context_nesting_end current=",
				    current);
		riscv_evl_trace_hex("EVLDBG riscv_v_context_nesting_end flags_before=",
				    READ_ONCE(current->thread.riscv_v_flags));
		riscv_evl_trace_hex("EVLDBG riscv_v_context_nesting_end sp=",
				    regs->sp);
	}

	if (!riscv_preempt_v_started(current))
		return;

	riscv_v_ctx_depth_dec();
	depth = riscv_v_ctx_get_depth();

	if (riscv_evl_trace_enabled())
		riscv_evl_trace_hex("EVLDBG riscv_v_context_nesting_end depth_after=",
				    depth);

	if (depth == 0) {
		if (riscv_preempt_v_restore(current)) {
			__riscv_v_vstate_restore(vstate, vstate->datap);
			__riscv_v_vstate_clean(regs);
			riscv_preempt_v_reset_flags();
			if (riscv_evl_trace_enabled())
				riscv_evl_trace("EVLDBG riscv_v_context_nesting_end restored");
		}
	}
}
#else
#define riscv_v_start_kernel_context(nested)	(-ENOENT)
#define riscv_v_stop_kernel_context()		(-ENOENT)
#endif

void kernel_vector_begin(void)
{
	bool nested = false;

	if (WARN_ON(!has_vector()))
		return;

	BUG_ON(!may_use_simd());

	if (riscv_v_start_kernel_context(&nested)) {
		get_cpu_vector_context();
		riscv_v_vstate_save(&current->thread.vstate, task_pt_regs(current));
	}

	if (!nested)
		riscv_v_vstate_set_restore(current, task_pt_regs(current));

	riscv_v_enable();
}
EXPORT_SYMBOL_GPL(kernel_vector_begin);

void kernel_vector_end(void)
{
	if (WARN_ON(!has_vector()))
		return;

	riscv_v_disable();

	if (riscv_v_stop_kernel_context())
		put_cpu_vector_context();
}
EXPORT_SYMBOL_GPL(kernel_vector_end);
