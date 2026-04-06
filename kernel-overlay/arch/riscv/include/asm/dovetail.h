/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RISC-V Dovetail arch hooks for EVL.
 *
 * Ported from arch/arm64/include/asm/dovetail.h
 * Copyright (C) 2018 Philippe Gerum <rpm@xenomai.org>
 *
 * RISC-V adaptation for SpacemiT K1 (2026).
 * FPU/Vector context save/restore is stubbed — add real hooks once
 * basic EVL boot is confirmed (dmesg: "EVL: core started").
 */
#ifndef _ASM_RISCV_DOVETAIL_H
#define _ASM_RISCV_DOVETAIL_H

/*
 * RISC-V exception/trap codes (scause values, interrupt bit clear).
 * Matches the RISC-V privileged spec §4.1.8 (Table 4.2).
 */
#define RISCV_TRAP_MISALIGNED_FETCH	0
#define RISCV_TRAP_FETCH_ACCESS		1
#define RISCV_TRAP_ILLEGAL_INSN		2
#define RISCV_TRAP_BREAKPOINT		3
#define RISCV_TRAP_MISALIGNED_LOAD	4
#define RISCV_TRAP_LOAD_ACCESS		5
#define RISCV_TRAP_MISALIGNED_STORE	6
#define RISCV_TRAP_STORE_ACCESS		7
#define RISCV_TRAP_ECALL_U		8
#define RISCV_TRAP_ECALL_S		9
#define RISCV_TRAP_ECALL_M		11
#define RISCV_TRAP_FETCH_PAGE		12
#define RISCV_TRAP_LOAD_PAGE		13
#define RISCV_TRAP_STORE_PAGE		15

#ifdef CONFIG_DOVETAIL

static inline void arch_dovetail_exec_prepare(void)
{ }

static inline void arch_dovetail_switch_prepare(bool leave_inband)
{ }

/*
 * Called when switching back to in-band context after an OOB section.
 * TODO: restore FPU/Vector state for OOB threads.
 * Stubbed for initial bring-up — sufficient to get EVL core started.
 */
static inline void arch_dovetail_switch_finish(bool enter_inband)
{ }

#define arch_dovetail_is_prctl(__nr)	((__nr) == __NR_prctl)

#endif /* CONFIG_DOVETAIL */

/*
 * Pass the trap event to the companion core. Return true if running
 * in-band afterwards.
 */
#define mark_cond_trap_entry(__trapnr, __regs)			\
	({							\
		bool __ret;					\
		oob_trap_notify(__trapnr, __regs);		\
		__ret = running_inband();			\
		if (!__ret)					\
			oob_trap_unwind(__trapnr, __regs);	\
		__ret;						\
	})

#define mark_trap_entry(__trapnr, __regs)				\
	do {								\
		bool __ret = mark_cond_trap_entry(__trapnr, __regs);	\
		BUG_ON(dovetail_debug() && !__ret);			\
	} while (0)

#define mark_trap_exit(__trapnr, __regs)				\
	oob_trap_unwind(__trapnr, __regs)

#endif /* _ASM_RISCV_DOVETAIL_H */
