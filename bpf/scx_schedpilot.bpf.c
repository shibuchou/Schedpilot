/* SPDX-License-Identifier: GPL-2.0 */
/*
 * scx_schedpilot - SchedPilot sched_ext scheduler (v0.3 provincial MVP)
 *
 * Three core DSQ paths:
 *   DSQ_LAT   : latency-sensitive sync tasks (short slice, dispatch priority,
 *               optional wakeup preemption)
 *   DSQ_COMP  : fair vtime path for compute tasks, NORMAL tasks and BG tasks
 *               (BG gets a configurable vtime penalty when BG_CONTAIN is on)
 *   DSQ_CACHE : memory-bound tasks (long slice, waker-LLC routing when
 *               LLCAFFINITY is on, migration penalty to reduce cache thrash)
 *
 * The userspace daemon (schedpilotd) owns the slow control loop and writes
 * struct sp_cfg through a pinned map. The BPF side only does O(1) lookups.
 * If the daemon heartbeat goes stale in adaptive mode the data plane falls
 * back to static, bounded defaults.
 */
#include <scx/common.bpf.h>
#include "intf.h"

char _license[] SEC("license") = "GPL";

UEI_DEFINE(uei);

/* static fallback defaults (ns) */
#define SP_DEF_LAT_SLICE_NS    1000000ULL
#define SP_DEF_COMP_SLICE_NS   4000000ULL
#define SP_DEF_CACHE_SLICE_NS  8000000ULL
#define SP_DEF_BG_SLICE_NS    10000000ULL
#define SP_DEF_PREEMPT_NS       500000ULL
#define SP_DEF_MIGRATE_PEN_NS  2000000ULL
#define SP_DEF_STARVE_NS      20000000ULL
#define SP_MAX_MIG_PEN_NS      8000000ULL
#define SP_DEF_BG_VTIME_PCT         200u
#define SP_MAX_RUN_DELAY_NS  1000000000ULL
#define SP_CLASS_TTL_NS       5000000000ULL

/* per-task context (task storage) */
struct sp_task_ctx {
	u64 enq_ns;
	u64 slice_ns;
	s32 last_cpu;
	u32 enq_depth;
};

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, u32);
	__type(value, struct sp_cfg);
} sp_cfg SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 16384);
	__type(key, u32);
	__type(value, struct sp_task_class);
} class_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 32768);
	__type(key, u32);
	__type(value, struct sp_tg_stats);
} tg_stats SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_TASK_STORAGE);
	__uint(map_flags, BPF_F_NO_PREALLOC);
	__type(key, int);
	__type(value, struct sp_task_ctx);
} task_ctx SEC(".maps");

/* cpu -> LLC domain id, written by schedpilotd before/while running */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1024);
	__type(key, u32);
	__type(value, u32);
} cpu_llc SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, SP_NR_STATS);
} stats SEC(".maps");

/* [0] = last preempt kick ns, [1] = cache/comp dispatch toggle,
 * [2] = last non-LAT dispatch ns (anti-starvation guard) */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 3);
} pcpu_state SEC(".maps");

static u64 vtime_now_comp;
static u64 vtime_now_cache;

static void stat_inc(u32 idx)
{
	u64 *cnt = bpf_map_lookup_elem(&stats, &idx);

	if (cnt)
		(*cnt)++;
}

static struct sp_cfg *get_cfg(void)
{
	u32 zero = 0;

	return bpf_map_lookup_elem(&sp_cfg, &zero);
}

static bool cfg_heartbeat_alive(struct sp_cfg *c)
{
	if (!c || c->intf_version != SP_INTF_VERSION)
		return false;
	if (!c->heartbeat_ns)
		return false;
	return (bpf_ktime_get_ns() - c->heartbeat_ns) < SP_HEARTBEAT_TIMEOUT_NS;
}

/*
 * Effective flags per mode:
 *  - BASIC ignores class routing and uses the shared DSQ only.
 *  - CLASS/ADAPTIVE use the class DSQs. In ADAPTIVE mode a stale daemon
 *    heartbeat degrades to the static flag set.
 */
static u32 effective_flags(struct sp_cfg *c)
{
	if (!c)
		return SP_FLAG_CLASS_DSQ | SP_FLAG_PREEMPT;

	switch (c->mode) {
	case SP_MODE_BASIC:
		return 0;
	case SP_MODE_CLASS:
		return c->flags | SP_FLAG_CLASS_DSQ;
	case SP_MODE_ADAPTIVE:
		if (!cfg_heartbeat_alive(c)) {
			stat_inc(SP_STAT_CFG_STALE);
			return SP_FLAG_CLASS_DSQ | SP_FLAG_PREEMPT;
		}
		stat_inc(SP_STAT_CFG_ALIVE);
		return c->flags | SP_FLAG_CLASS_DSQ;
	default:
		return SP_FLAG_CLASS_DSQ | SP_FLAG_PREEMPT;
	}
}

static u64 pick_slice(struct sp_cfg *c, u32 klass)
{
	u64 v;

	switch (klass) {
	case SP_CLASS_LAT:
		v = c ? c->lat_slice_ns : 0;
		return v ? v : SP_DEF_LAT_SLICE_NS;
	case SP_CLASS_CACHE:
		v = c ? c->cache_slice_ns : 0;
		return v ? v : SP_DEF_CACHE_SLICE_NS;
	case SP_CLASS_BG:
		v = c ? c->bg_slice_ns : 0;
		return v ? v : SP_DEF_BG_SLICE_NS;
	default:
		v = c ? c->comp_slice_ns : 0;
		return v ? v : SP_DEF_COMP_SLICE_NS;
	}
}

static u32 lookup_class(struct task_struct *p)
{
	u32 tgid = p->tgid;
	struct sp_task_class *tc = bpf_map_lookup_elem(&class_map, &tgid);

	if (tc) {
		u64 now = bpf_ktime_get_ns();

		/* Stale classifications expire (daemon heartbeat is the
		 * liveness source; a dead/restarted daemon must not leave old
		 * PIDs classified forever, e.g. after PID reuse). */
		if (!tc->updated_ns ||
		    now - tc->updated_ns > SP_CLASS_TTL_NS) {
			stat_inc(SP_STAT_CLASSMAP_EXPIRED);
			return SP_CLASS_NORMAL;
		}
		stat_inc(SP_STAT_CLASSMAP_HIT);
		if (tc->klass <= SP_CLASS_MAX)
			return tc->klass;
		stat_inc(SP_STAT_CLASSMAP_INVALID);
		return SP_CLASS_NORMAL;
	}
	stat_inc(SP_STAT_CLASSMAP_MISS);
	return SP_CLASS_NORMAL;
}

static void stat_running(u32 klass)
{
	switch (klass) {
	case SP_CLASS_LAT:
		stat_inc(SP_STAT_RUN_LAT);
		break;
	case SP_CLASS_COMP:
		stat_inc(SP_STAT_RUN_COMP);
		break;
	case SP_CLASS_CACHE:
		stat_inc(SP_STAT_RUN_CACHE);
		break;
	case SP_CLASS_BG:
		stat_inc(SP_STAT_RUN_BG);
		break;
	default:
		stat_inc(SP_STAT_RUN_NORMAL);
		break;
	}
}

static void stat_direct(u32 klass)
{
	switch (klass) {
	case SP_CLASS_LAT:
		stat_inc(SP_STAT_DIRECT_LAT);
		break;
	case SP_CLASS_COMP:
		stat_inc(SP_STAT_DIRECT_COMP);
		break;
	case SP_CLASS_CACHE:
		stat_inc(SP_STAT_DIRECT_CACHE);
		break;
	default:
		stat_inc(SP_STAT_DIRECT_NORMAL);
		break;
	}
}

/* per-tgid scheduling event counters consumed by schedpilotd */
enum sp_tg_field {
	SP_TG_WAKEUPS = 0,
	SP_TG_SWITCHES = 1,
	SP_TG_RUNTIME = 2,
	SP_TG_RUN_DELAY = 3,
};

static void tg_stat_add(u32 tgid, u32 field, u64 val)
{
	struct sp_tg_stats *s = bpf_map_lookup_elem(&tg_stats, &tgid);

	if (!s) {
		struct sp_tg_stats init = {};

		bpf_map_update_elem(&tg_stats, &tgid, &init, BPF_NOEXIST);
		s = bpf_map_lookup_elem(&tg_stats, &tgid);
		if (!s)
			return;
	}

	switch (field) {
	case SP_TG_WAKEUPS:
		__sync_fetch_and_add(&s->wakeups, val);
		break;
	case SP_TG_SWITCHES:
		__sync_fetch_and_add(&s->switches, val);
		break;
	case SP_TG_RUNTIME:
		__sync_fetch_and_add(&s->runtime_ns, val);
		break;
	case SP_TG_RUN_DELAY:
		__sync_fetch_and_add(&s->run_delay_ns, val);
		break;
	default:
		break;
	}
	s->last_update_ns = bpf_ktime_get_ns();
}

static struct sp_task_ctx *get_task_ctx(struct task_struct *p, bool create)
{
	u64 flags = create ? BPF_LOCAL_STORAGE_GET_F_CREATE : 0;

	return bpf_task_storage_get(&task_ctx, p, NULL, flags);
}

static u64 task_weight(struct task_struct *p)
{
	return p->scx.weight ? p->scx.weight : 100;
}

static void vtime_floor(struct task_struct *p, u64 now, u64 slice)
{
	if (time_before(p->scx.dsq_vtime, now - slice))
		p->scx.dsq_vtime = now - slice;
}

static u64 cache_dsq_for_cpu(u32 cpu)
{
	u32 *llc_p = bpf_map_lookup_elem(&cpu_llc, &cpu);
	u32 llc = llc_p ? *llc_p : 0;

	if (llc >= SP_MAX_LLC)
		llc = 0;
	return SP_DSQ_CACHE_BASE + llc;
}

s32 BPF_STRUCT_OPS(schedpilot_select_cpu, struct task_struct *p, s32 prev_cpu,
		   u64 wake_flags)
{
	struct sp_cfg *c = get_cfg();
	u32 flags = effective_flags(c);
	u32 klass = lookup_class(p);
	bool is_idle = false;
	s32 cpu;

	/*
	 * select_cpu is the wakeup path (including direct local dispatch,
	 * which never reaches enqueue). Count wakeups here so L-SYNC
	 * detection works even when most wakeups are served directly.
	 */
	tg_stat_add(p->tgid, SP_TG_WAKEUPS, 1);

	cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
	if (is_idle) {
		stat_direct(klass);
		scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, pick_slice(c, klass), 0);
		return cpu;
	}

	if ((flags & SP_FLAG_PREEMPT) && cpu >= 0 && klass != SP_CLASS_BG) {
		u32 zero = 0;
		u64 *last_kick = bpf_map_lookup_elem(&pcpu_state, &zero);
		u64 now = bpf_ktime_get_ns();
		u64 thr = (c && c->preempt_thresh_ns) ? c->preempt_thresh_ns
						      : SP_DEF_PREEMPT_NS;

		/* LAT wakes preempt aggressively; other classes use a wider
		 * threshold so throughput-oriented tasks (DB sync threads)
		 * still get prompt wakeups without a preemption storm. */
		if (klass != SP_CLASS_LAT)
			thr *= 4;

		if (last_kick && (now - *last_kick) >= thr) {
			*last_kick = now;
			stat_inc(SP_STAT_PREEMPT_KICK);
			scx_bpf_kick_cpu(cpu, SCX_KICK_PREEMPT);
		} else {
			stat_inc(SP_STAT_PREEMPT_RATELIMITED);
		}
	}

	return cpu;
}

void BPF_STRUCT_OPS(schedpilot_enqueue, struct task_struct *p, u64 enq_flags)
{
	struct sp_cfg *c = get_cfg();
	u32 flags = effective_flags(c);
	u32 klass = lookup_class(p);
	u64 slice = pick_slice(c, klass);
	struct sp_task_ctx *tc;

	tc = get_task_ctx(p, true);
	if (tc) {
		if (tc->enq_depth == 0) {
			tc->enq_ns = bpf_ktime_get_ns();
			tc->slice_ns = slice;
		}
		tc->enq_depth++;
	}

	if (!(flags & SP_FLAG_CLASS_DSQ)) {
		stat_inc(SP_STAT_ENQ_SHARED);
		stat_inc(SP_STAT_ENQ_VTIME_SHARED);
		vtime_floor(p, vtime_now_comp, slice);
		scx_bpf_dsq_insert_vtime(p, SP_DSQ_SHARED, slice,
					 p->scx.dsq_vtime, enq_flags);
		return;
	}

	switch (klass) {
	case SP_CLASS_LAT:
		stat_inc(SP_STAT_ENQ_LAT);
		scx_bpf_dsq_insert(p, SP_DSQ_LAT, slice, enq_flags);
		break;
	case SP_CLASS_CACHE: {
		u64 dsq;

		stat_inc(SP_STAT_ENQ_CACHE);
		stat_inc(SP_STAT_ENQ_VTIME_CACHE);
		if (flags & SP_FLAG_LLC_AFFINITY)
			dsq = cache_dsq_for_cpu(bpf_get_smp_processor_id());
		else
			dsq = SP_DSQ_CACHE_BASE;
		vtime_floor(p, vtime_now_cache, slice);
		scx_bpf_dsq_insert_vtime(p, dsq, slice, p->scx.dsq_vtime,
					 enq_flags);
		break;
	}
	case SP_CLASS_BG:
		stat_inc(SP_STAT_ENQ_BG);
		stat_inc(SP_STAT_ENQ_VTIME_COMP);
		vtime_floor(p, vtime_now_comp, slice);
		scx_bpf_dsq_insert_vtime(p, SP_DSQ_COMP, slice,
					 p->scx.dsq_vtime, enq_flags);
		break;
	default:
		stat_inc(SP_STAT_ENQ_COMP);
		stat_inc(SP_STAT_ENQ_VTIME_COMP);
		vtime_floor(p, vtime_now_comp, slice);
		scx_bpf_dsq_insert_vtime(p, SP_DSQ_COMP, slice,
					 p->scx.dsq_vtime, enq_flags);
		break;
	}
}

void BPF_STRUCT_OPS(schedpilot_running, struct task_struct *p)
{
	struct sp_cfg *c = get_cfg();
	u32 flags = effective_flags(c);
	u32 klass = lookup_class(p);
	u32 cpu = bpf_get_smp_processor_id();
	struct sp_task_ctx *tc;

	stat_running(klass);

	tc = get_task_ctx(p, false);
	if (tc) {
		if (tc->enq_depth) {
			u64 now = bpf_ktime_get_ns();

			if (now > tc->enq_ns && now - tc->enq_ns < SP_MAX_RUN_DELAY_NS)
				tg_stat_add(p->tgid, SP_TG_RUN_DELAY,
					    now - tc->enq_ns);
			tc->enq_depth = 0;
		}
		if (klass == SP_CLASS_CACHE && (flags & SP_FLAG_LLC_AFFINITY) &&
		    tc->last_cpu >= 0 && tc->last_cpu != (s32)cpu) {
			u64 pen = (c && c->migrate_penalty_ns) ?
					  c->migrate_penalty_ns :
					  SP_DEF_MIGRATE_PEN_NS;

			p->scx.dsq_vtime += pen * 100 / task_weight(p);
			/* Cap accumulated migration penalty: a frequently
			 * migrating task must not be buried far beyond the
			 * current vtime watermark (starves its class). */
			if (time_before(vtime_now_cache + SP_MAX_MIG_PEN_NS,
					p->scx.dsq_vtime))
				p->scx.dsq_vtime = vtime_now_cache +
						   SP_MAX_MIG_PEN_NS;
			stat_inc(SP_STAT_CACHE_MIGRATED);
		}
		tc->last_cpu = cpu;
	}

	if (klass == SP_CLASS_CACHE) {
		if (time_before(vtime_now_cache, p->scx.dsq_vtime))
			vtime_now_cache = p->scx.dsq_vtime;
	} else {
		if (time_before(vtime_now_comp, p->scx.dsq_vtime))
			vtime_now_comp = p->scx.dsq_vtime;
	}
}

void BPF_STRUCT_OPS(schedpilot_stopping, struct task_struct *p, bool runnable)
{
	struct sp_cfg *c = get_cfg();
	u32 klass = lookup_class(p);
	struct sp_task_ctx *tc = get_task_ctx(p, false);
	u64 slice = (tc && tc->slice_ns) ? tc->slice_ns : pick_slice(c, klass);
	u64 consumed = slice > p->scx.slice ? slice - p->scx.slice : 0;
	u64 weight = task_weight(p);
	u64 cost;

	tg_stat_add(p->tgid, SP_TG_SWITCHES, 1);
	tg_stat_add(p->tgid, SP_TG_RUNTIME, consumed);

	cost = consumed * 100 / weight;
	if (klass == SP_CLASS_BG && c && (c->flags & SP_FLAG_BG_CONTAIN)) {
		u32 pct = c->bg_vtime_pct ? c->bg_vtime_pct : SP_DEF_BG_VTIME_PCT;

		cost = cost * pct / 100;
		stat_inc(SP_STAT_BG_VTIME_PENALTY);
	}
	p->scx.dsq_vtime += cost;
}

void BPF_STRUCT_OPS(schedpilot_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now_comp;
}

static int dispatch_cache(s32 this_cpu)
{
	u32 *llc_p = bpf_map_lookup_elem(&cpu_llc, &this_cpu);
	u32 start = llc_p ? (*llc_p % SP_MAX_LLC) : 0;
	u32 i;

	stat_inc(SP_STAT_DSQ_CACHE_TRY);
#pragma unroll
	for (i = 0; i < SP_MAX_LLC; i++) {
		u32 dsq = SP_DSQ_CACHE_BASE + ((start + i) % SP_MAX_LLC);

		if (scx_bpf_dsq_move_to_local(dsq)) {
			stat_inc(SP_STAT_DSQ_CACHE_HIT);
			stat_inc(SP_STAT_DSP_CACHE);
			return 1;
		}
	}
	return 0;
}

void BPF_STRUCT_OPS(schedpilot_dispatch, s32 cpu, struct task_struct *prev)
{
	u32 one = 1, two_stat = 2;
	u64 *toggle = bpf_map_lookup_elem(&pcpu_state, &one);
	u64 *last_other = bpf_map_lookup_elem(&pcpu_state, &two_stat);
	bool cache_first = !toggle || ((*toggle & 1) == 0);
	bool moved = false;
	struct sp_cfg *c = get_cfg();
	u64 now = bpf_ktime_get_ns();
	u64 starve = (c && c->starvation_ns) ? c->starvation_ns
					     : SP_DEF_STARVE_NS;
	/* LAT must not starve the throughput classes: if no non-LAT task
	 * has been dispatched for a while, serve CACHE/COMP first. */
	bool force_other = last_other &&
			   (*last_other == 0 || (now - *last_other) >= starve);

	stat_inc(SP_STAT_DISPATCH_CALLS);

	if (!force_other && scx_bpf_dsq_move_to_local(SP_DSQ_LAT)) {
		stat_inc(SP_STAT_DSP_LAT);
		return;
	}

	if (cache_first)
		moved = dispatch_cache(cpu);
	else if (scx_bpf_dsq_move_to_local(SP_DSQ_COMP)) {
		stat_inc(SP_STAT_DSP_COMP);
		moved = true;
	}

	if (!moved) {
		if (!cache_first)
			moved = dispatch_cache(cpu);
		else if (scx_bpf_dsq_move_to_local(SP_DSQ_COMP)) {
			stat_inc(SP_STAT_DSP_COMP);
			moved = true;
		}
	}

	if (moved) {
		if (toggle)
			*toggle ^= 1;
		if (last_other)
			*last_other = now;
		return;
	}

	if (force_other && scx_bpf_dsq_move_to_local(SP_DSQ_LAT)) {
		stat_inc(SP_STAT_DSP_LAT);
		if (last_other)
			*last_other = now;
		return;
	}

	if (scx_bpf_dsq_move_to_local(SP_DSQ_SHARED))
		stat_inc(SP_STAT_DSP_SHARED);
}

s32 BPF_STRUCT_OPS_SLEEPABLE(schedpilot_init)
{
	s32 ret;
	u32 i;

	ret = scx_bpf_create_dsq(SP_DSQ_SHARED, -1);
	if (ret)
		return ret;
	ret = scx_bpf_create_dsq(SP_DSQ_LAT, -1);
	if (ret)
		return ret;
	ret = scx_bpf_create_dsq(SP_DSQ_COMP, -1);
	if (ret)
		return ret;

#pragma unroll
	for (i = 0; i < SP_MAX_LLC; i++) {
		ret = scx_bpf_create_dsq(SP_DSQ_CACHE_BASE + i, -1);
		if (ret)
			return ret;
	}
	return 0;
}

void BPF_STRUCT_OPS(schedpilot_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(schedpilot_ops,
	       .select_cpu		= (void *)schedpilot_select_cpu,
	       .enqueue			= (void *)schedpilot_enqueue,
	       .dispatch		= (void *)schedpilot_dispatch,
	       .running			= (void *)schedpilot_running,
	       .stopping		= (void *)schedpilot_stopping,
	       .enable			= (void *)schedpilot_enable,
	       .init			= (void *)schedpilot_init,
	       .exit			= (void *)schedpilot_exit,
	       .name			= "schedpilot");
