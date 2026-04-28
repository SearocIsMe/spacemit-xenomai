// SPDX-License-Identifier: GPL-2.0
#include <linux/bitops.h>
#include <linux/fault-inject-usercopy.h>
#include <linux/instrumented.h>
#include <linux/irqflags.h>
#include <linux/irq_pipeline.h>
#include <linux/irqstage.h>
#include <linux/nospec.h>
#include <linux/preempt.h>
#include <linux/uaccess.h>

/* out-of-line parts */

#ifdef CONFIG_IRQ_PIPELINE
static __always_inline void usercopy_bootdbg_irq_context_fix(const char *op)
{
	static int log_budget = 64;
	bool need_fix;
	bool do_log;

	if (pagefault_disabled() || in_atomic())
		return;

	need_fix = test_inband_stall() || irqs_disabled() ||
		hard_irqs_disabled();
	do_log = need_fix && log_budget > 0;

	if (!need_fix)
		return;

	if (do_log) {
		log_budget--;
		pr_notice("BOOTDBG usercopy_irq_fix before op=%s stall=%d irqs_disabled=%d hard_irqs_disabled=%d current=%s[%d]\n",
			  op, test_inband_stall(), irqs_disabled(),
			  hard_irqs_disabled(), current->comm, task_pid_nr(current));
	}

	if (test_inband_stall())
		unstall_inband_nocheck();
	local_irq_enable_full();

	if (do_log)
		pr_notice("BOOTDBG usercopy_irq_fix after op=%s stall=%d irqs_disabled=%d hard_irqs_disabled=%d current=%s[%d]\n",
			  op, test_inband_stall(), irqs_disabled(),
			  hard_irqs_disabled(), current->comm, task_pid_nr(current));
}
#else
static __always_inline void usercopy_bootdbg_irq_context_fix(const char *op)
{
}
#endif

#ifndef INLINE_COPY_FROM_USER
unsigned long _copy_from_user(void *to, const void __user *from, unsigned long n)
{
	unsigned long res = n;

	usercopy_bootdbg_irq_context_fix("from_user");
	might_fault();
	if (!should_fail_usercopy() && likely(access_ok(from, n))) {
		/*
		 * Ensure that bad access_ok() speculation will not
		 * lead to nasty side effects *after* the copy is
		 * finished:
		 */
		barrier_nospec();
		instrument_copy_from_user_before(to, from, n);
		res = raw_copy_from_user(to, from, n);
		instrument_copy_from_user_after(to, from, n, res);
	}
	if (unlikely(res))
		memset(to + (n - res), 0, res);
	return res;
}
EXPORT_SYMBOL(_copy_from_user);
#endif

#ifndef INLINE_COPY_TO_USER
unsigned long _copy_to_user(void __user *to, const void *from, unsigned long n)
{
	usercopy_bootdbg_irq_context_fix("to_user");
	might_fault();
	if (should_fail_usercopy())
		return n;
	if (likely(access_ok(to, n))) {
		instrument_copy_to_user(to, from, n);
		n = raw_copy_to_user(to, from, n);
	}
	return n;
}
EXPORT_SYMBOL(_copy_to_user);
#endif

/**
 * check_zeroed_user: check if a userspace buffer only contains zero bytes
 * @from: Source address, in userspace.
 * @size: Size of buffer.
 *
 * This is effectively shorthand for "memchr_inv(from, 0, size) == NULL" for
 * userspace addresses (and is more efficient because we don't care where the
 * first non-zero byte is).
 *
 * Returns:
 *  * 0: There were non-zero bytes present in the buffer.
 *  * 1: The buffer was full of zero bytes.
 *  * -EFAULT: access to userspace failed.
 */
int check_zeroed_user(const void __user *from, size_t size)
{
	unsigned long val;
	uintptr_t align = (uintptr_t) from % sizeof(unsigned long);

	if (unlikely(size == 0))
		return 1;

	from -= align;
	size += align;

	if (!user_read_access_begin(from, size))
		return -EFAULT;

	unsafe_get_user(val, (unsigned long __user *) from, err_fault);
	if (align)
		val &= ~aligned_byte_mask(align);

	while (size > sizeof(unsigned long)) {
		if (unlikely(val))
			goto done;

		from += sizeof(unsigned long);
		size -= sizeof(unsigned long);

		unsafe_get_user(val, (unsigned long __user *) from, err_fault);
	}

	if (size < sizeof(unsigned long))
		val &= aligned_byte_mask(size);

done:
	user_read_access_end();
	return (val == 0);
err_fault:
	user_read_access_end();
	return -EFAULT;
}
EXPORT_SYMBOL(check_zeroed_user);
