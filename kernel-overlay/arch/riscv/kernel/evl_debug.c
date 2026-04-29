// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/spinlock.h>

#include <asm/evl_debug.h>
#include <asm/sbi.h>

bool riscv_evl_early_debug_enabled;
bool riscv_evl_runtime_trace_enabled;
static DEFINE_RAW_SPINLOCK(riscv_evl_trace_lock);

#ifndef SBI_EXT_0_1_CONSOLE_PUTCHAR
#define SBI_EXT_0_1_CONSOLE_PUTCHAR 0x1
#endif

static int __init setup_riscv_evl_early_debug(char *arg)
{
	riscv_evl_early_debug_enabled = true;
	riscv_evl_runtime_trace_enabled = true;
	pr_info("EVL early debug: enabled (evl_debug kernel param found)\n");
	return 0;
}
early_param("evl_debug", setup_riscv_evl_early_debug);

static __always_inline void riscv_evl_sbi_putchar(int ch)
{
	sbi_ecall(SBI_EXT_0_1_CONSOLE_PUTCHAR, 0, ch, 0, 0, 0, 0, 0);
}

void riscv_evl_early_puts(const char *s)
{
	if (!riscv_evl_early_debug_enabled || !s)
		return;

	while (*s) {
		if (*s == '\n')
			riscv_evl_sbi_putchar('\r');
		riscv_evl_sbi_putchar(*s++);
	}
}

void riscv_evl_early_puthex_ulong(unsigned long value)
{
	static const char hexdigits[] = "0123456789abcdef";
	char buf[2 + sizeof(unsigned long) * 2];
	int i;

	buf[0] = '0';
	buf[1] = 'x';
	for (i = 0; i < (int)(sizeof(unsigned long) * 2); i++) {
		unsigned int shift = ((sizeof(unsigned long) * 2 - 1 - i) * 4);
		buf[2 + i] = hexdigits[(value >> shift) & 0xf];
	}

	for (i = 0; i < (int)sizeof(buf); i++)
		riscv_evl_sbi_putchar(buf[i]);
}

void riscv_evl_trace_sched_switch(unsigned long cpu,
				  const void *prev, long prev_pid,
				  unsigned long prev_cpu,
				  unsigned long prev_on_cpu,
				  const char *prev_comm,
				  const void *next, long next_pid,
				  unsigned long next_cpu,
				  unsigned long next_on_cpu,
				  const char *next_comm)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts("EVLDBG __schedule switch cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" prev=");
	riscv_evl_early_puthex_ulong((unsigned long)prev);
	riscv_evl_early_puts(" prev_pid=");
	riscv_evl_early_puthex_ulong((unsigned long)prev_pid);
	riscv_evl_early_puts(" prev_task_cpu=");
	riscv_evl_early_puthex_ulong(prev_cpu);
	riscv_evl_early_puts(" prev_on_cpu=");
	riscv_evl_early_puthex_ulong(prev_on_cpu);
	riscv_evl_early_puts(" prev_comm=");
	riscv_evl_early_puts(prev_comm);
	riscv_evl_early_puts(" next=");
	riscv_evl_early_puthex_ulong((unsigned long)next);
	riscv_evl_early_puts(" next_pid=");
	riscv_evl_early_puthex_ulong((unsigned long)next_pid);
	riscv_evl_early_puts(" next_task_cpu=");
	riscv_evl_early_puthex_ulong(next_cpu);
	riscv_evl_early_puts(" next_on_cpu=");
	riscv_evl_early_puthex_ulong(next_on_cpu);
	riscv_evl_early_puts(" next_comm=");
	riscv_evl_early_puts(next_comm);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_cpuhp_state(const char *tag,
				 unsigned long cpu,
				 unsigned long bringup,
				 unsigned long state,
				 unsigned long target,
				 unsigned long should_run,
				 unsigned long result)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" bringup=");
	riscv_evl_early_puthex_ulong(bringup);
	riscv_evl_early_puts(" state=");
	riscv_evl_early_puthex_ulong(state);
	riscv_evl_early_puts(" target=");
	riscv_evl_early_puthex_ulong(target);
	riscv_evl_early_puts(" should_run=");
	riscv_evl_early_puthex_ulong(should_run);
	riscv_evl_early_puts(" result=");
	riscv_evl_early_puthex_ulong(result);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_worker_state(const char *tag,
				  unsigned long pool_cpu,
				  unsigned long pool_id,
				  const void *pool,
				  const void *task,
				  unsigned long task_cpu,
				  unsigned long task_state,
				  unsigned long worker_flags)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" pool_cpu=");
	riscv_evl_early_puthex_ulong(pool_cpu);
	riscv_evl_early_puts(" pool_id=");
	riscv_evl_early_puthex_ulong(pool_id);
	riscv_evl_early_puts(" pool=");
	riscv_evl_early_puthex_ulong((unsigned long)pool);
	riscv_evl_early_puts(" task=");
	riscv_evl_early_puthex_ulong((unsigned long)task);
	riscv_evl_early_puts(" task_cpu=");
	riscv_evl_early_puthex_ulong(task_cpu);
	riscv_evl_early_puts(" task_state=");
	riscv_evl_early_puthex_ulong(task_state);
	riscv_evl_early_puts(" worker_flags=");
	riscv_evl_early_puthex_ulong(worker_flags);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_smpboot_state(const char *tag,
				   unsigned long cpu,
				   unsigned long status,
				   unsigned long selfparking,
				   unsigned long should_park,
				   unsigned long should_run)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" status=");
	riscv_evl_early_puthex_ulong(status);
	riscv_evl_early_puts(" selfparking=");
	riscv_evl_early_puthex_ulong(selfparking);
	riscv_evl_early_puts(" should_park=");
	riscv_evl_early_puthex_ulong(should_park);
	riscv_evl_early_puts(" should_run=");
	riscv_evl_early_puthex_ulong(should_run);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_task_stack_state(const char *tag,
				      unsigned long cpu,
				      const void *task,
				      long pid,
				      unsigned long task_cpu,
				      unsigned long current_sp,
				      unsigned long ti_kernel_sp,
				      unsigned long thread_sp,
				      const void *task_regs)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" task=");
	riscv_evl_early_puthex_ulong((unsigned long)task);
	riscv_evl_early_puts(" pid=");
	riscv_evl_early_puthex_ulong((unsigned long)pid);
	riscv_evl_early_puts(" task_cpu=");
	riscv_evl_early_puthex_ulong(task_cpu);
	riscv_evl_early_puts(" current_sp=");
	riscv_evl_early_puthex_ulong(current_sp);
	riscv_evl_early_puts(" ti_kernel_sp=");
	riscv_evl_early_puthex_ulong(ti_kernel_sp);
	riscv_evl_early_puts(" thread_sp=");
	riscv_evl_early_puthex_ulong(thread_sp);
	riscv_evl_early_puts(" task_pt_regs=");
	riscv_evl_early_puthex_ulong((unsigned long)task_regs);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_idle_state(const char *tag,
				unsigned long cpu,
				const void *task,
				long pid,
				unsigned long need_resched,
				unsigned long polling,
				unsigned long preempt_need_resched)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" task=");
	riscv_evl_early_puthex_ulong((unsigned long)task);
	riscv_evl_early_puts(" pid=");
	riscv_evl_early_puthex_ulong((unsigned long)pid);
	riscv_evl_early_puts(" need_resched=");
	riscv_evl_early_puthex_ulong(need_resched);
	riscv_evl_early_puts(" polling=");
	riscv_evl_early_puthex_ulong(polling);
	riscv_evl_early_puts(" preempt_need_resched=");
	riscv_evl_early_puthex_ulong(preempt_need_resched);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}

void riscv_evl_trace_resched_state(const char *tag,
				   unsigned long cpu,
				   const void *task,
				   long pid,
				   unsigned long need_resched,
				   unsigned long preempt_count_value,
				   unsigned long irqs_disabled)
{
	unsigned long flags;

	if (!riscv_evl_early_debug_enabled || !riscv_evl_runtime_trace_enabled)
		return;

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	riscv_evl_early_puts(tag);
	riscv_evl_early_puts(" cpu=");
	riscv_evl_early_puthex_ulong(cpu);
	riscv_evl_early_puts(" task=");
	riscv_evl_early_puthex_ulong((unsigned long)task);
	riscv_evl_early_puts(" pid=");
	riscv_evl_early_puthex_ulong((unsigned long)pid);
	riscv_evl_early_puts(" need_resched=");
	riscv_evl_early_puthex_ulong(need_resched);
	riscv_evl_early_puts(" preempt_count=");
	riscv_evl_early_puthex_ulong(preempt_count_value);
	riscv_evl_early_puts(" irqs_disabled=");
	riscv_evl_early_puthex_ulong(irqs_disabled);
	riscv_evl_early_puts("\n");
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}
