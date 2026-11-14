// SPDX-License-Identifier: GPL-2.0
/*
 * StormBreaker: CPU frequency floor for the vendor low-battery cap.
 *
 * Why this is here at all: on the target device (POCO rodin, MT6899) the
 * vendor thermal daemon /vendor/bin/mi_thermald has a rule, GL-MONITOR-BCL,
 * that looks only at the battery percentage:
 *
 *     SOC <= 5%   cpu0 cluster capped at 1.2 GHz, cpu3 and cpu7 offlined
 *     SOC <= 1%   cpu0 and cpu4 clusters capped at 800 MHz,
 *                 cpu4 and cpu7 offlined; released only at SOC >= 2%
 *
 * The daemon writes "cpuN <kHz>" to /sys/class/thermal/thermal_message/
 * cpu_limits, and the vendor module mi_thermal_interface turns that into a
 * FREQ_QOS_MAX request through freq_qos_update_request(), which lives here in
 * the GKI core. /vendor is read-only under dm-verity, so the rule cannot be
 * edited without breaking the AVB chain.
 *
 * The 800 MHz step is what makes the phone crawl when it is plugged in at 1%:
 * the cap stays until the percentage climbs, exactly while the release of
 * battery saver starts the deferred work of every app at once. Measured on the
 * device with the BCL state reproduced (6 cores, cold start of Settings):
 *
 *     cap        alone    with 6 competing processes
 *     800 MHz    1100 ms  1596 ms
 *     1.2 GHz     687 ms  1085 ms
 *     no cap      411 ms  (8 cores)
 *
 * What this does: while the battery is at or below SB_LBF_MAX_SOC percent,
 * any FREQ_QOS_MAX request owned by mi_thermal_interface that asks for less
 * than SB_LBF_FLOOR_KHZ is applied as SB_LBF_FLOOR_KHZ instead. The value the
 * module asked for is remembered and restored as soon as the condition ends.
 *
 * Deliberate limits, so that every thermal limit keeps working:
 *   - Only requests added by mi_thermal_interface are touched. The kernel's
 *     own limiters (MediaTek low-battery, peak power budget and battery
 *     over-current throttling, cpufreq cooling devices) use requests of their
 *     own and are never seen here.
 *   - The daemon combines its thermal and BCL rules into one value per
 *     cluster, so a thermal cap and the BCL cap arrive through the same
 *     request. Below 44 C on the daemon's VIRTUAL-SENSOR, none of its thermal
 *     rules asks for less than 1.2 GHz (the lowest are 1.2 GHz on cpu0 from
 *     25 C, 1.0 GHz on cpu4/cpu7 from 47 C and 500 MHz on cpu0 from 48 C), so
 *     a 1.2 GHz floor can only ever lift the BCL step. Above the guard the
 *     floor steps aside; it comes back below the guard minus 2 C.
 *   - The VIRTUAL-SENSOR is recomputed here with the daemon's own weights
 *     (from its decrypted config, /data/vendor/thermal/decrypt.txt). On the
 *     device it matched the daemon's published value within 0.1 C.
 *   - Any failure to read the battery or a thermal zone turns the floor off,
 *     which is the stock behaviour.
 *   - CPU offlining is left alone.
 *   - Runtime kill switch: /sys/module/stormbreaker_lbf/parameters/enable
 *     (active, soc and virtual_temp_mc report the current state).
 */

#define pr_fmt(fmt) "StormBreaker: " fmt

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/pm_qos.h>
#include <linux/power_supply.h>
#include <linux/string.h>
#include <linux/thermal.h>
#include <linux/workqueue.h>

#include "stormbreaker_lbf.h"

#undef MODULE_PARAM_PREFIX
#define MODULE_PARAM_PREFIX "stormbreaker_lbf."

#define SB_LBF_OWNER		"mi_thermal_interface"
/*
 * Do not raise this without redoing the thermal analysis above: cpu0 is
 * thermally capped at exactly 1.2 GHz from 25 C, and a higher floor would
 * override that cap.
 */
#define SB_LBF_FLOOR_KHZ	1200000
#define SB_LBF_MAX_SOC		5
#define SB_LBF_GUARD_MC		44000
#define SB_LBF_HYST_MC		2000
#define SB_LBF_SLOTS		8
#define SB_LBF_FAST		(2 * HZ)	/* the daemon polls every 2 s */
#define SB_LBF_SLOW		(10 * HZ)

static const struct {
	const char *zone;
	int weight;
} sb_lbf_vs[] = {
	{ "battery",		 345 },
	{ "quiet_therm",	 257 },
	{ "wifi_therm",		  66 },
	{ "mtktsAP",		-204 },
	{ "mtktsbtsmdpa",	 -28 },
	{ "mtktsbtsnrpa",	 382 },
	{ "charger1_therm",	 140 },
};
#define SB_LBF_VS_WEIGHT_SUM	1000
#define SB_LBF_VS_COMP_MC	1130

static bool sb_lbf_enable = true;
module_param_named(enable, sb_lbf_enable, bool, 0644);
MODULE_PARM_DESC(enable, "Apply the low-battery CPU frequency floor");

/* Read-only status, for whoever debugs this later. */
static bool sb_lbf_active;
module_param_named(active, sb_lbf_active, bool, 0444);
static int sb_lbf_soc = -1;
module_param_named(soc, sb_lbf_soc, int, 0444);
static int sb_lbf_vs_mc;
module_param_named(virtual_temp_mc, sb_lbf_vs_mc, int, 0444);
static unsigned int sb_lbf_floor = SB_LBF_FLOOR_KHZ;
module_param_named(floor_khz, sb_lbf_floor, uint, 0444);

struct sb_lbf_slot {
	struct freq_qos_request *req;
	s32 requested;
};

static struct sb_lbf_slot sb_lbf_slots[SB_LBF_SLOTS];
static int sb_lbf_nr;
static DEFINE_MUTEX(sb_lbf_lock);

static void sb_lbf_work_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(sb_lbf_work, sb_lbf_work_fn);

static bool sb_lbf_caller_is_owner(unsigned long addr)
{
	struct module *mod;
	bool owner;

	preempt_disable();
	mod = __module_address(addr);
	owner = mod && !strcmp(mod->name, SB_LBF_OWNER);
	preempt_enable();

	return owner;
}

static s32 sb_lbf_target(s32 requested)
{
	if (READ_ONCE(sb_lbf_active) && requested < SB_LBF_FLOOR_KHZ)
		return SB_LBF_FLOOR_KHZ;
	return requested;
}

/* Lockless pre-check: most freq_qos updates in the system are not ours. */
static bool sb_lbf_maybe_tracked(struct freq_qos_request *req)
{
	int i;

	if (!READ_ONCE(sb_lbf_nr))
		return false;
	for (i = 0; i < SB_LBF_SLOTS; i++)
		if (READ_ONCE(sb_lbf_slots[i].req) == req)
			return true;
	return false;
}

static struct sb_lbf_slot *sb_lbf_find(struct freq_qos_request *req)
{
	int i;

	lockdep_assert_held(&sb_lbf_lock);
	for (i = 0; i < SB_LBF_SLOTS; i++)
		if (sb_lbf_slots[i].req == req)
			return &sb_lbf_slots[i];
	return NULL;
}

bool sb_lbf_add(struct freq_qos_request *req, s32 value,
		unsigned long caller, int *ret)
{
	struct sb_lbf_slot *slot;
	bool first;

	if (req->type != FREQ_QOS_MAX || !sb_lbf_caller_is_owner(caller))
		return false;

	mutex_lock(&sb_lbf_lock);
	slot = sb_lbf_find(NULL);
	if (!slot) {
		mutex_unlock(&sb_lbf_lock);
		pr_warn_once("low-battery floor: no free slot, request left alone\n");
		return false;
	}

	*ret = freq_qos_apply(req, PM_QOS_ADD_REQ, sb_lbf_target(value));
	if (*ret < 0) {
		mutex_unlock(&sb_lbf_lock);
		return true;
	}

	slot->requested = value;
	WRITE_ONCE(slot->req, req);
	first = !sb_lbf_nr;
	WRITE_ONCE(sb_lbf_nr, sb_lbf_nr + 1);
	mutex_unlock(&sb_lbf_lock);

	if (first) {
		pr_info("low-battery floor: tracking %s frequency caps\n",
			SB_LBF_OWNER);
		queue_delayed_work(system_power_efficient_wq, &sb_lbf_work, 0);
	}
	return true;
}

bool sb_lbf_update(struct freq_qos_request *req, s32 value, int *ret)
{
	struct sb_lbf_slot *slot;
	s32 target;

	if (!sb_lbf_maybe_tracked(req))
		return false;

	mutex_lock(&sb_lbf_lock);
	slot = sb_lbf_find(req);
	if (!slot) {
		mutex_unlock(&sb_lbf_lock);
		return false;
	}

	slot->requested = value;
	target = sb_lbf_target(value);
	*ret = req->pnode.prio == target ? 0 :
	       freq_qos_apply(req, PM_QOS_UPDATE_REQ, target);
	mutex_unlock(&sb_lbf_lock);

	return true;
}

void sb_lbf_remove(struct freq_qos_request *req)
{
	struct sb_lbf_slot *slot;

	if (!sb_lbf_maybe_tracked(req))
		return;

	mutex_lock(&sb_lbf_lock);
	slot = sb_lbf_find(req);
	if (slot) {
		WRITE_ONCE(slot->req, NULL);
		WRITE_ONCE(sb_lbf_nr, sb_lbf_nr - 1);
	}
	mutex_unlock(&sb_lbf_lock);
}

static bool sb_lbf_read_soc(int *soc)
{
	struct power_supply *psy;
	union power_supply_propval val;
	int err;

	psy = power_supply_get_by_name("battery");
	if (!psy)
		return false;
	err = power_supply_get_property(psy, POWER_SUPPLY_PROP_CAPACITY, &val);
	power_supply_put(psy);
	if (err)
		return false;

	*soc = val.intval;
	return true;
}

static bool sb_lbf_read_vs(int *vs_mc)
{
	s64 sum = 0;
	int i;

	for (i = 0; i < ARRAY_SIZE(sb_lbf_vs); i++) {
		struct thermal_zone_device *tz;
		int temp;

		tz = thermal_zone_get_zone_by_name(sb_lbf_vs[i].zone);
		if (IS_ERR(tz) || thermal_zone_get_temp(tz, &temp))
			return false;
		sum += (s64)sb_lbf_vs[i].weight * temp;
	}

	*vs_mc = (int)div_s64(sum, SB_LBF_VS_WEIGHT_SUM) + SB_LBF_VS_COMP_MC;
	return true;
}

static void sb_lbf_work_fn(struct work_struct *work)
{
	unsigned long next = SB_LBF_SLOW;
	bool was = READ_ONCE(sb_lbf_active);
	bool want = false;
	const char *why;
	int soc = -1, vs = 0, i;

	if (!READ_ONCE(sb_lbf_enable)) {
		why = "disabled";
	} else if (!sb_lbf_read_soc(&soc)) {
		why = "battery unreadable";
	} else {
		WRITE_ONCE(sb_lbf_soc, soc);
		if (soc > SB_LBF_MAX_SOC) {
			why = "battery above threshold";
			if (soc <= SB_LBF_MAX_SOC + 1)
				next = SB_LBF_FAST;
		} else {
			next = SB_LBF_FAST;
			if (!sb_lbf_read_vs(&vs)) {
				why = "thermal zone unreadable";
			} else {
				int guard = was ? SB_LBF_GUARD_MC :
					    SB_LBF_GUARD_MC - SB_LBF_HYST_MC;

				WRITE_ONCE(sb_lbf_vs_mc, vs);
				want = vs < guard;
				why = "virtual sensor at thermal guard";
			}
		}
	}

	mutex_lock(&sb_lbf_lock);
	WRITE_ONCE(sb_lbf_active, want);
	for (i = 0; i < SB_LBF_SLOTS; i++) {
		struct freq_qos_request *req = sb_lbf_slots[i].req;
		s32 target;

		if (!req)
			continue;
		target = sb_lbf_target(sb_lbf_slots[i].requested);
		if (req->pnode.prio != target)
			freq_qos_apply(req, PM_QOS_UPDATE_REQ, target);
	}
	mutex_unlock(&sb_lbf_lock);

	if (want != was) {
		if (want)
			pr_info("low-battery floor on: %u kHz (battery %d%%, virtual sensor %d mC)\n",
				SB_LBF_FLOOR_KHZ, soc, vs);
		else
			pr_info("low-battery floor off: %s\n", why);
	}

	if (READ_ONCE(sb_lbf_nr))
		queue_delayed_work(system_power_efficient_wq, &sb_lbf_work, next);
}
