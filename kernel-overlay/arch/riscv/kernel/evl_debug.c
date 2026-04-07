// SPDX-License-Identifier: GPL-2.0
#include <linux/init.h>

#include <asm/evl_debug.h>
#include <asm/sbi.h>

bool riscv_evl_early_debug_enabled;

static int __init setup_riscv_evl_early_debug(char *arg)
{
	riscv_evl_early_debug_enabled = true;
	return 0;
}
early_param("evl_debug", setup_riscv_evl_early_debug);

void riscv_evl_early_puts(const char *s)
{
	if (!riscv_evl_early_debug_enabled || !s)
		return;

	while (*s) {
		if (*s == '\n')
			sbi_console_putchar('\r');
		sbi_console_putchar(*s++);
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
		sbi_console_putchar(buf[i]);
}
