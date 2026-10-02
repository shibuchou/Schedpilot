/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SchedPilot shared interface between the sched_ext BPF data plane,
 * the scx_schedpilot loader and the schedpilotd control daemon.
 *
 * Keep this header free of libbpf/kernel dependencies so both sides can
 * include it. Bump SP_INTF_VERSION on any layout change.
 */
#ifndef __SCHEDPILOT_INTF_H
#define __SCHEDPILOT_INTF_H

#ifndef __SCHEDPILOT_BPF__
#include <linux/types.h>
#endif

#define SP_INTF_VERSION 1

/* control modes */
#define SP_MODE_BASIC    0 /* B: single shared DSQ (basic sched_ext) */
#define SP_MODE_CLASS    1 /* C: class DSQs, static policy, classification on */
#define SP_MODE_ADAPTIVE 2 /* D: class DSQs + adaptive policy from schedpilotd */

/* cfg flags */
#define SP_FLAG_CLASS_DSQ    (1u << 0) /* use LAT/COMP/CACHE DSQ routing */
#define SP_FLAG_PREEMPT      (1u << 1) /* kick PREEMPT for LAT wakeups */
#define SP_FLAG_LLC_AFFINITY (1u << 2) /* waker-LLC routing + migration penalty */
#define SP_FLAG_BG_CONTAIN   (1u << 3) /* deprioritize BG via vtime penalty */
#define SP_FLAG_CLASSIFY     (1u << 4) /* daemon classification is active */

/* task classes */
#define SP_CLASS_NORMAL 0
#define SP_CLASS_LAT    1
#define SP_CLASS_COMP   2
#define SP_CLASS_CACHE  3
#define SP_CLASS_BG     4
#define SP_CLASS_MAX    4

/* class sources */
#define SP_SRC_NONE   0
#define SP_SRC_RULES  1
#define SP_SRC_EXTERN 2

/* DSQ ids */
#define SP_DSQ_SHARED     0
#define SP_DSQ_LAT        1
#define SP_DSQ_COMP       2
#define SP_DSQ_CACHE_BASE 8
#define SP_MAX_LLC        8

#define SP_HEARTBEAT_TIMEOUT_NS 2000000000ULL

struct sp_cfg {
	__u32 intf_version;
	__u32 generation;
	__u32 mode;
	__u32 flags;
	__u32 heartbeat_seq;
	__u32 reserved0;
	__u64 heartbeat_ns;
	__u64 lat_slice_ns;
	__u64 comp_slice_ns;
	__u64 cache_slice_ns;
	__u64 bg_slice_ns;
	__u64 preempt_thresh_ns;
	__u64 starvation_ns;
	__u64 migrate_penalty_ns;
	__u32 lat_vtime_pct;
	__u32 bg_vtime_pct;
	__u32 klass_update_epoch;
	__u32 reserved1;
};

struct sp_task_class {
	__u32 klass;
	__u32 confidence; /* 0..1000 */
	__u64 updated_ns;
	__u32 source; /* SP_SRC_* */
	__u32 reserved;
};

struct sp_tg_stats {
	__u64 wakeups;
	__u64 switches;
	__u64 runtime_ns;
	__u64 run_delay_ns;
	__u64 last_update_ns;
};

/* statistics indices (PERCPU_ARRAY, u64 counters) */
#define SP_STAT_ENQ_LAT              0
#define SP_STAT_ENQ_COMP             1
#define SP_STAT_ENQ_CACHE            2
#define SP_STAT_ENQ_BG               3
#define SP_STAT_ENQ_SHARED           4
#define SP_STAT_DSP_LAT              5
#define SP_STAT_DSP_COMP             6
#define SP_STAT_DSP_CACHE            7
#define SP_STAT_DSP_SHARED           8
#define SP_STAT_RUN_NORMAL           9
#define SP_STAT_RUN_LAT              10
#define SP_STAT_RUN_COMP             11
#define SP_STAT_RUN_CACHE            12
#define SP_STAT_RUN_BG               13
#define SP_STAT_DIRECT_LAT           14
#define SP_STAT_DIRECT_COMP          15
#define SP_STAT_DIRECT_CACHE         16
#define SP_STAT_DIRECT_NORMAL        17
#define SP_STAT_PREEMPT_KICK         18
#define SP_STAT_PREEMPT_RATELIMITED  19
#define SP_STAT_CLASSMAP_HIT         20
#define SP_STAT_CLASSMAP_MISS        21
#define SP_STAT_CLASSMAP_INVALID     22
#define SP_STAT_CACHE_MIGRATED       23
#define SP_STAT_BG_VTIME_PENALTY     24
#define SP_STAT_DISPATCH_CALLS       25
#define SP_STAT_ENQ_VTIME_COMP       26
#define SP_STAT_ENQ_VTIME_CACHE      27
#define SP_STAT_ENQ_VTIME_SHARED     28
#define SP_STAT_CFG_ALIVE            29
#define SP_STAT_CFG_STALE            30
#define SP_STAT_DSQ_CACHE_TRY        31
#define SP_STAT_DSQ_CACHE_HIT        32
#define SP_STAT_CLASSMAP_EXPIRED     33
#define SP_NR_STATS                  40

#endif /* __SCHEDPILOT_INTF_H */
