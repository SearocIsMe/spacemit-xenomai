/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _EVL_RISCV_ASM_UAPI_FPTEST_H
#define _EVL_RISCV_ASM_UAPI_FPTEST_H

#include <linux/types.h>

/*
 * Minimal placeholder for RISC-V EVL FPU self-tests.
 * We currently advertise no architecture-specific FPU test features.
 */
#define evl_riscv_no_fpu 0x0

#define evl_set_fpregs(__features, __val)		do { } while (0)
#define evl_check_fpregs(__features, __val, __bad)	({ (__bad) = -1; (__val); })

#endif /* !_EVL_RISCV_ASM_UAPI_FPTEST_H */
