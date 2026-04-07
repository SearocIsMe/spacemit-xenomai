/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ASM_RISCV_EVL_DEBUG_H
#define _ASM_RISCV_EVL_DEBUG_H

#include <linux/types.h>

#ifdef CONFIG_IRQ_PIPELINE
extern bool riscv_evl_early_debug_enabled;

void riscv_evl_early_puts(const char *s);
void riscv_evl_early_puthex_ulong(unsigned long value);

static inline void riscv_evl_trace(const char *tag)
{
	if (riscv_evl_early_debug_enabled)
		riscv_evl_early_puts(tag);
}

static inline void riscv_evl_trace_ulong(const char *prefix, unsigned long value)
{
	if (!riscv_evl_early_debug_enabled)
		return;

	riscv_evl_early_puts(prefix);
	riscv_evl_early_puthex_ulong(value);
	riscv_evl_early_puts("\n");
}
#else
static const bool riscv_evl_early_debug_enabled;

static inline void riscv_evl_early_puts(const char *s) { }
static inline void riscv_evl_early_puthex_ulong(unsigned long value) { }
static inline void riscv_evl_trace(const char *tag) { }
static inline void riscv_evl_trace_ulong(const char *prefix, unsigned long value) { }
#endif

#endif
