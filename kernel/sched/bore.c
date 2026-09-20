// SPDX-License-Identifier: GPL-2.0
/*
 *  Burst-Oriented Response Enhancer (BORE) CPU Scheduler
 *  Copyright (C) 2021-2024 Masahito Suzuki <firelzrd@gmail.com>
 *
 *  Ported to the Android Common Kernel (android15-6.6) for StormBreaker.
 *  Upstream: https://github.com/firelzrd/bore-scheduler
 *  Based on: patches/stable/linux-6.6-bore/0001-linux6.6.107-bore5.9.6.patch
 *            (BORE 5.9.6, rebased on Linux 6.6.107)
 *
 *  Why this file differs from the upstream patch
 *  ---------------------------------------------
 *  This kernel has a frozen KMI (generation android15-8) and must keep loading
 *  the device's stock vendor modules. Those modules carry symbol CRCs, and
 *  kernel/module/version.c:same_magic() skips the release string when CRCs are
 *  present -- so what gates module loading is the CRCs, not the version.
 *  Any change to a type reachable from the KMI changes those CRCs and makes
 *  every vendor module fail to load.
 *
 *  Upstream BORE grows struct sched_entity by ~60 bytes. Since sched_entity is
 *  embedded by value in task_struct, that would shift every task_struct member
 *  after it. Instead, the per-entity state here lives in ANDROID_KABI_USE()
 *  slots, which expand back to the original u64 reservations under
 *  __GENKSYMS__, leaving the CRCs untouched.
 *
 *  Only 32 bytes of reservation exist (4 slots x 8 bytes) and slots 3 and 4 are
 *  deliberately left free, so the two struct sched_burst_cache members and
 *  sched_burst_fork_atavistic were dropped. They implement burst inheritance
 *  from parent/thread-group at fork() time -- a refinement, not the core
 *  algorithm. Everything that makes BORE work (accumulating burst_time in
 *  update_curr(), deriving the penalty, and applying it in update_entity_lag(),
 *  place_entity() and pick_eevdf()) is intact. A forked task simply starts from
 *  its own smoothed history rather than inheriting the parent's.
 *
 *  min_base_slice_ns/base_slice_ns are exposed twice on purpose: through
 *  debugfs in kernel/sched/debug.c (where upstream BORE puts them, so existing
 *  BORE tooling keeps working) and through sysctl here. The sysctl path is the
 *  one to rely on -- it does not depend on CONFIG_SCHED_DEBUG/DEBUG_FS staying
 *  enabled, and /proc/sys is reachable from init scripts and tuning apps that
 *  cannot count on debugfs being mounted.
 */
#include <linux/cpuset.h>
#include <linux/sched/task.h>
#include <linux/sched/bore.h>
#include "sched.h"

#ifdef CONFIG_SCHED_BORE

u8   __read_mostly sched_bore                   = 1;
u8   __read_mostly sched_burst_exclude_kthreads = 1;
u8   __read_mostly sched_burst_smoothness_long  = 1;
u8   __read_mostly sched_burst_smoothness_short = 0;
u8   __read_mostly sched_burst_parity_threshold = 2;
u8   __read_mostly sched_burst_penalty_offset   = 24;
uint __read_mostly sched_burst_penalty_scale    = 1280;
uint __read_mostly sched_deadline_boost_mask    = ENQUEUE_INITIAL
						| ENQUEUE_WAKEUP;

static int __maybe_unused sixty_four     = 64;
static int __maybe_unused maxval_u8      = 255;
static int __maybe_unused maxval_12_bits = 4095;

#define MAX_BURST_PENALTY (39U << 2)

static inline u32 log2plus1_u64_u32f8(u64 v)
{
	u32 integral = fls64(v);
	u8  fractional = v << (64 - integral) >> 55;

	return integral << 8 | fractional;
}

static inline u32 calc_burst_penalty(u64 burst_time)
{
	u32 greed, tolerance, penalty, scaled_penalty;

	greed = log2plus1_u64_u32f8(burst_time);
	tolerance = sched_burst_penalty_offset << 8;
	penalty = max(0, (s32)(greed - tolerance));
	scaled_penalty = penalty * sched_burst_penalty_scale >> 16;

	return min(MAX_BURST_PENALTY, scaled_penalty);
}

static inline u64 __scale_slice(u64 delta, u8 score)
{
	return mul_u64_u32_shr(delta, sched_prio_to_wmult[score], 22);
}

static inline u64 __unscale_slice(u64 delta, u8 score)
{
	return mul_u64_u32_shr(delta, sched_prio_to_weight[score], 10);
}

static void reweight_task_by_prio(struct task_struct *p, int prio)
{
	struct sched_entity *se = &p->se;
	unsigned long weight = scale_load(sched_prio_to_weight[prio]);

	reweight_entity(cfs_rq_of(se), se, weight);
	se->load.inv_weight = sched_prio_to_wmult[prio];
}

static inline u8 effective_prio(struct task_struct *p)
{
	u8 prio = p->static_prio - MAX_RT_PRIO;

	if (likely(sched_bore))
		prio += p->se.burst_score;

	return min(39, prio);
}

void update_burst_score(struct sched_entity *se)
{
	struct task_struct *p;
	u8 prev_prio, new_prio, burst_score = 0;

	if (!entity_is_task(se))
		return;

	p = task_of(se);
	prev_prio = effective_prio(p);

	if (!((p->flags & PF_KTHREAD) && likely(sched_burst_exclude_kthreads)))
		burst_score = se->burst_penalty >> 2;
	se->burst_score = burst_score;

	new_prio = effective_prio(p);
	if (new_prio != prev_prio)
		reweight_task_by_prio(p, new_prio);
}

void update_burst_penalty(struct sched_entity *se)
{
	se->curr_burst_penalty = calc_burst_penalty(se->burst_time);
	se->burst_penalty = max(se->prev_burst_penalty, se->curr_burst_penalty);
	update_burst_score(se);
}

static inline u32 binary_smooth(u32 new, u32 old)
{
	int increment = new - old;

	return (0 <= increment) ?
		old + ( increment >> (int)sched_burst_smoothness_long) :
		old - (-increment >> (int)sched_burst_smoothness_short);
}

static void revolve_burst_penalty(struct sched_entity *se)
{
	se->prev_burst_penalty =
		binary_smooth(se->curr_burst_penalty, se->prev_burst_penalty);
	se->burst_time = 0;
	se->curr_burst_penalty = 0;
}

void restart_burst(struct sched_entity *se)
{
	revolve_burst_penalty(se);
	se->burst_penalty = se->prev_burst_penalty;
	update_burst_score(se);
}

void restart_burst_rescale_deadline(struct sched_entity *se)
{
	s64 vscaled, wremain, vremain = se->deadline - se->vruntime;
	struct task_struct *p = task_of(se);
	u8 prev_prio = effective_prio(p);
	u8 new_prio;

	restart_burst(se);
	new_prio = effective_prio(p);

	if (prev_prio > new_prio) {
		wremain = __unscale_slice(abs(vremain), prev_prio);
		vscaled = __scale_slice(wremain, new_prio);
		if (unlikely(vremain < 0))
			vscaled = -vscaled;
		se->deadline = se->vruntime + vscaled;
	}
}

static inline bool task_is_bore_eligible(struct task_struct *p)
{
	return p && p->sched_class == &fair_sched_class && !p->exit_state;
}

static void reset_task_weights_bore(void)
{
	struct task_struct *task;
	struct rq *rq;
	struct rq_flags rf;

	write_lock_irq(&tasklist_lock);
	for_each_process(task) {
		if (!task_is_bore_eligible(task))
			continue;
		rq = task_rq(task);
		rq_pin_lock(rq, &rf);
		update_rq_clock(rq);
		reweight_task_by_prio(task, effective_prio(task));
		rq_unpin_lock(rq, &rf);
	}
	write_unlock_irq(&tasklist_lock);
}

int sched_bore_update_handler(struct ctl_table *table, int write,
		void *buffer, size_t *lenp, loff_t *ppos)
{
	int ret = proc_dou8vec_minmax(table, write, buffer, lenp, ppos);

	if (ret || !write)
		return ret;

	reset_task_weights_bore();

	return 0;
}

/*
 * Upstream inherits a burst penalty from the parent (or thread group) here,
 * using the child_burst/group_burst caches. Those caches do not fit the
 * available KMI padding, so a forked task starts from its own smoothed
 * history instead. clone_flags/now are kept in the signature so the call site
 * in kernel/fork.c matches upstream and a future revision can restore
 * inheritance without touching callers.
 */
void sched_clone_bore(struct task_struct *p, struct task_struct *parent,
		u64 clone_flags, u64 now)
{
	struct sched_entity *se = &p->se;

	if (!task_is_bore_eligible(p))
		return;

	revolve_burst_penalty(se);
	se->burst_penalty = se->prev_burst_penalty;
}

void reset_task_bore(struct task_struct *p)
{
	p->se.burst_time = 0;
	p->se.prev_burst_penalty = 0;
	p->se.curr_burst_penalty = 0;
	p->se.burst_penalty = 0;
	p->se.burst_score = 0;
}

void __init sched_bore_init(void)
{
	pr_info("BORE (Burst-Oriented Response Enhancer) CPU Scheduler modification %s by Masahito Suzuki\n",
		SCHED_BORE_VERSION);
	reset_task_bore(&init_task);
}

#ifdef CONFIG_SYSCTL
/*
 * Writing min_base_slice_ns has to recompute base_slice_ns, which upstream
 * does from its debugfs setter. Same effect, sysctl path.
 */
static int sched_min_base_slice_handler(struct ctl_table *table, int write,
		void *buffer, size_t *lenp, loff_t *ppos)
{
	int ret = proc_douintvec_minmax(table, write, buffer, lenp, ppos);

	if (ret || !write)
		return ret;

	sched_update_min_base_slice();

	return 0;
}

static struct ctl_table sched_bore_sysctls[] = {
	{
		.procname	= "sched_bore",
		.data		= &sched_bore,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= sched_bore_update_handler,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
	{
		.procname	= "sched_burst_exclude_kthreads",
		.data		= &sched_burst_exclude_kthreads,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= proc_dou8vec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
	{
		.procname	= "sched_burst_smoothness_long",
		.data		= &sched_burst_smoothness_long,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= proc_dou8vec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
	{
		.procname	= "sched_burst_smoothness_short",
		.data		= &sched_burst_smoothness_short,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= proc_dou8vec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
	{
		.procname	= "sched_burst_parity_threshold",
		.data		= &sched_burst_parity_threshold,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= proc_dou8vec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= &maxval_u8,
	},
	{
		.procname	= "sched_burst_penalty_offset",
		.data		= &sched_burst_penalty_offset,
		.maxlen		= sizeof(u8),
		.mode		= 0644,
		.proc_handler	= proc_dou8vec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= &sixty_four,
	},
	{
		.procname	= "sched_burst_penalty_scale",
		.data		= &sched_burst_penalty_scale,
		.maxlen		= sizeof(uint),
		.mode		= 0644,
		.proc_handler	= proc_douintvec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= &maxval_12_bits,
	},
	{
		.procname	= "sched_deadline_boost_mask",
		.data		= &sched_deadline_boost_mask,
		.maxlen		= sizeof(uint),
		.mode		= 0644,
		.proc_handler	= proc_douintvec,
	},
	/*
	 * Upstream exposes these two through debugfs (kernel/sched/debug.c),
	 * which is not built here because CONFIG_SCHED_DEBUG is off.
	 */
	{
		.procname	= "sched_min_base_slice_ns",
		.data		= &sysctl_sched_min_base_slice,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= sched_min_base_slice_handler,
		.extra1		= SYSCTL_ONE,
	},
	{
		.procname	= "sched_base_slice_ns",
		.data		= &sysctl_sched_base_slice,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0444,
		.proc_handler	= proc_douintvec,
	},
};

static int __init sched_bore_sysctl_init(void)
{
	register_sysctl_init("kernel", sched_bore_sysctls);
	return 0;
}
late_initcall(sched_bore_sysctl_init);
#endif /* CONFIG_SYSCTL */

#endif /* CONFIG_SCHED_BORE */
