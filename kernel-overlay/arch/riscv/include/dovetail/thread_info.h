/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RISC-V Dovetail per-thread OOB state.
 *
 * The actual oob_thread_state struct is defined by the EVL co-kernel
 * in include/asm-generic/evl/thread_info.h (struct evl_thread pointer,
 * subscriber pointer, preempt_count). When CONFIG_EVL is not set, it
 * falls back to an empty struct.
 */
#ifndef _RISCV_DOVETAIL_THREAD_INFO_H
#define _RISCV_DOVETAIL_THREAD_INFO_H

#include <asm-generic/evl/thread_info.h>

#endif /* _RISCV_DOVETAIL_THREAD_INFO_H */
