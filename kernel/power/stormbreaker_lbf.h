/* SPDX-License-Identifier: GPL-2.0 */
/*
 * StormBreaker: CPU frequency floor for the vendor low-battery cap.
 * Hooks called from the frequency QoS core in kernel/power/qos.c.
 */
#ifndef _KERNEL_POWER_STORMBREAKER_LBF_H
#define _KERNEL_POWER_STORMBREAKER_LBF_H

#include <linux/pm_qos.h>

#ifdef CONFIG_STORMBREAKER_LOWBAT_FREQ_FLOOR
bool sb_lbf_add(struct freq_qos_request *req, s32 value,
		unsigned long caller, int *ret);
bool sb_lbf_update(struct freq_qos_request *req, s32 value, int *ret);
void sb_lbf_remove(struct freq_qos_request *req);
#else
static inline bool sb_lbf_add(struct freq_qos_request *req, s32 value,
			      unsigned long caller, int *ret)
{
	return false;
}
static inline bool sb_lbf_update(struct freq_qos_request *req, s32 value,
				 int *ret)
{
	return false;
}
static inline void sb_lbf_remove(struct freq_qos_request *req) { }
#endif

#endif /* _KERNEL_POWER_STORMBREAKER_LBF_H */
