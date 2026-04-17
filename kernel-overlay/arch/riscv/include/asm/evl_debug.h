/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ASM_RISCV_EVL_DEBUG_H
#define _ASM_RISCV_EVL_DEBUG_H

#include <linux/types.h>

#ifdef CONFIG_IRQ_PIPELINE
extern bool riscv_evl_early_debug_enabled;

void riscv_evl_early_puts(const char *s);
void riscv_evl_early_puthex_ulong(unsigned long value);
void riscv_evl_trace_sched_switch(unsigned long cpu,
				  const void *prev, long prev_pid,
				  unsigned long prev_cpu,
				  unsigned long prev_on_cpu,
				  const char *prev_comm,
				  const void *next, long next_pid,
				  unsigned long next_cpu,
				  unsigned long next_on_cpu,
				  const char *next_comm);
void riscv_evl_trace_cpuhp_state(const char *tag,
				 unsigned long cpu,
				 unsigned long bringup,
				 unsigned long state,
				 unsigned long target,
				 unsigned long should_run,
				 unsigned long result);
void riscv_evl_trace_worker_state(const char *tag,
				  unsigned long pool_cpu,
				  unsigned long pool_id,
				  const void *pool,
				  const void *task,
				  unsigned long task_cpu,
				  unsigned long task_state,
				  unsigned long worker_flags);
void riscv_evl_trace_smpboot_state(const char *tag,
				   unsigned long cpu,
				   unsigned long status,
				   unsigned long selfparking,
				   unsigned long should_park,
				   unsigned long should_run);
void riscv_evl_trace_task_stack_state(const char *tag,
				      unsigned long cpu,
				      const void *task,
				      long pid,
				      unsigned long task_cpu,
				      unsigned long current_sp,
				      unsigned long ti_kernel_sp,
				      unsigned long thread_sp,
				      const void *task_regs);

static inline void riscv_evl_trace(const char *tag)
{
	if (riscv_evl_early_debug_enabled)
		riscv_evl_early_puts(tag);
}

static inline bool riscv_evl_trace_enabled(void)
{
	return riscv_evl_early_debug_enabled;
}

static inline void riscv_evl_trace_ulong(const char *prefix, unsigned long value)
{
	if (!riscv_evl_early_debug_enabled)
		return;

	riscv_evl_early_puts(prefix);
	riscv_evl_early_puthex_ulong(value);
	riscv_evl_early_puts("\n");
}

static inline void riscv_evl_trace_hex(const char *prefix, unsigned long value)
{
	riscv_evl_trace_ulong(prefix, value);
}

static inline void riscv_evl_trace_ptr(const char *prefix, const void *ptr)
{
	riscv_evl_trace_ulong(prefix, (unsigned long)ptr);
}
#else
static const bool riscv_evl_early_debug_enabled;

static inline void riscv_evl_early_puts(const char *s) { }
static inline void riscv_evl_early_puthex_ulong(unsigned long value) { }
static inline void riscv_evl_trace_sched_switch(unsigned long cpu,
						const void *prev, long prev_pid,
						unsigned long prev_cpu,
						unsigned long prev_on_cpu,
						const char *prev_comm,
						const void *next, long next_pid,
						unsigned long next_cpu,
						unsigned long next_on_cpu,
						const char *next_comm) { }
static inline void riscv_evl_trace_cpuhp_state(const char *tag,
					       unsigned long cpu,
					       unsigned long bringup,
					       unsigned long state,
					       unsigned long target,
					       unsigned long should_run,
					       unsigned long result) { }
static inline void riscv_evl_trace_worker_state(const char *tag,
						unsigned long pool_cpu,
						unsigned long pool_id,
						const void *pool,
						const void *task,
						unsigned long task_cpu,
						unsigned long task_state,
						unsigned long worker_flags) { }
static inline void riscv_evl_trace_smpboot_state(const char *tag,
						 unsigned long cpu,
						 unsigned long status,
						 unsigned long selfparking,
						 unsigned long should_park,
						 unsigned long should_run) { }
static inline void riscv_evl_trace_task_stack_state(const char *tag,
						    unsigned long cpu,
						    const void *task,
						    long pid,
						    unsigned long task_cpu,
						    unsigned long current_sp,
						    unsigned long ti_kernel_sp,
						    unsigned long thread_sp,
						    const void *task_regs) { }
static inline void riscv_evl_trace(const char *tag) { }
static inline bool riscv_evl_trace_enabled(void) { return false; }
static inline void riscv_evl_trace_ulong(const char *prefix, unsigned long value) { }
static inline void riscv_evl_trace_hex(const char *prefix, unsigned long value) { }
static inline void riscv_evl_trace_ptr(const char *prefix, const void *ptr) { }
#endif

#endif
