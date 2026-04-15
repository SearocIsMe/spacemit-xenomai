// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/spinlock.h>

#include <asm/evl_debug.h>
#include <asm/sbi.h>

bool riscv_evl_early_debug_enabled;
static DEFINE_RAW_SPINLOCK(riscv_evl_trace_lock);

#ifndef SBI_EXT_0_1_CONSOLE_PUTCHAR
#define SBI_EXT_0_1_CONSOLE_PUTCHAR 0x1
#endif

static int __init setup_riscv_evl_early_debug(char *arg)
{
	riscv_evl_early_debug_enabled = true;
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
	char buf[256];
	int len;

	if (!riscv_evl_early_debug_enabled)
		return;

	len = scnprintf(buf, sizeof(buf),
			"EVLDBG __schedule switch cpu=%#lx prev=%px prev_pid=%ld prev_task_cpu=%#lx prev_on_cpu=%#lx prev_comm=%s next=%px next_pid=%ld next_task_cpu=%#lx next_on_cpu=%#lx next_comm=%s\n",
			cpu, prev, prev_pid, prev_cpu, prev_on_cpu, prev_comm,
			next, next_pid, next_cpu, next_on_cpu, next_comm);

	raw_spin_lock_irqsave(&riscv_evl_trace_lock, flags);
	buf[len] = '\0';
	riscv_evl_early_puts(buf);
	raw_spin_unlock_irqrestore(&riscv_evl_trace_lock, flags);
}
