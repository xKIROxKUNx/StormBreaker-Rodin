/* SPDX-License-Identifier: GPL-2.0 */
/*
 *  Burst-Oriented Response Enhancer (BORE) CPU Scheduler
 *  Copyright (C) 2021-2024 Masahito Suzuki <firelzrd@gmail.com>
 *
 *  Ported to the Android Common Kernel (android15-6.6) for StormBreaker.
 *  Upstream: https://github.com/firelzrd/bore-scheduler
 *  Based on: patches/stable/linux-6.6-bore/0001-linux6.6.107-bore5.9.6.patch
 *
 *  Divergences from upstream BORE 5.9.6, required by the frozen GKI KMI
 *  (KMI generation android15-8) -- see kernel/sched/bore.c for the rationale:
 *
 *    - Per-entity state lives in ANDROID_KABI_USE() slots of struct
 *      sched_entity, so the struct keeps its frozen size and every existing
 *      member keeps its offset. Under __GENKSYMS__ the slots expand back to
 *      the original reservations, so exported-symbol CRCs are unchanged and
 *      the stock vendor modules still load.
 *    - sched_burst_fork_atavistic and the two struct sched_burst_cache
 *      members are dropped: they did not fit the available padding, and they
 *      only drive burst inheritance across fork(), not the core algorithm.
 *    - The debugfs knobs are exposed through sysctl instead, because
 *      CONFIG_SCHED_DEBUG is off in the GKI configuration.
 */
#ifndef _LINUX_SCHED_BORE_H
#define _LINUX_SCHED_BORE_H

#include <linux/sched.h>
#include <linux/sched/cputime.h>

#define SCHED_BORE_VERSION "5.9.6"

#ifdef CONFIG_SCHED_BORE

struct cfs_rq;
struct ctl_table;

extern u8   __read_mostly sched_bore;
extern u8   __read_mostly sched_burst_exclude_kthreads;
extern u8   __read_mostly sched_burst_smoothness_long;
extern u8   __read_mostly sched_burst_smoothness_short;
extern u8   __read_mostly sched_burst_parity_threshold;
extern u8   __read_mostly sched_burst_penalty_offset;
extern uint __read_mostly sched_burst_penalty_scale;
extern uint __read_mostly sched_deadline_boost_mask;

extern void update_burst_score(struct sched_entity *se);
extern void update_burst_penalty(struct sched_entity *se);

extern void restart_burst(struct sched_entity *se);
extern void restart_burst_rescale_deadline(struct sched_entity *se);

extern int sched_bore_update_handler(struct ctl_table *table, int write,
		void *buffer, size_t *lenp, loff_t *ppos);

extern void sched_clone_bore(struct task_struct *p,
		struct task_struct *parent, u64 clone_flags, u64 now);

extern void reset_task_bore(struct task_struct *p);
extern void sched_bore_init(void);

/* De-staticized in fair.c so reweight_task_by_prio() can reach it. */
extern void reweight_entity(struct cfs_rq *cfs_rq, struct sched_entity *se,
		unsigned long weight);

#endif /* CONFIG_SCHED_BORE */
#endif /* _LINUX_SCHED_BORE_H */
