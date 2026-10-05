/* SPDX-License-Identifier: GPL-2.0 */
/*
 * scx_schedpilot - userspace loader for the SchedPilot sched_ext scheduler.
 *
 * The loader owns the scheduler lifetime. The schedpilotd daemon only talks
 * to the pinned BPF maps, so the data plane keeps running (or safely falls
 * back) if the control daemon exits or crashes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <libgen.h>
#include <errno.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <scx/common.h>
#include "scx_schedpilot.bpf.skel.h"
#include "intf.h"

const char help_fmt[] =
"SchedPilot sched_ext scheduler (v0.3 provincial MVP).\n"
"\n"
"Usage: %s [--mode basic|class|adaptive] [--status] [--stats] [--monitor N]\n"
"          [--detach] [-v] [-h]\n"
"\n"
"  --mode MODE    Initial control mode (default: adaptive)\n"
"                   basic    : single shared DSQ, no classification\n"
"                   class    : LAT/COMP/CACHE DSQs with static policy\n"
"                   adaptive : class DSQs + schedpilotd adaptive policy\n"
"  --status       Print sched_ext state and SchedPilot cfg summary, then exit\n"
"  --stats        Print pinned counters/cfg, then exit\n"
"  --monitor N    Print stats every N seconds while running\n"
"  --detach       Refuse unsafe global detach; stop via schedpilotctl.sh\n"
"  -v             Verbose libbpf messages\n"
"  -h             This help\n";

static bool verbose;
static bool status_only;
static bool stats_only;
static bool detach_only;
static volatile int exit_req;
static double monitor_interval;
static const char *mode_name = "adaptive";
static const char *pin_dir = "/sys/fs/bpf/schedpilot/v1";

static const char *stat_names[SP_NR_STATS] = {
	[SP_STAT_ENQ_LAT] = "enq_lat",
	[SP_STAT_ENQ_COMP] = "enq_comp",
	[SP_STAT_ENQ_CACHE] = "enq_cache",
	[SP_STAT_ENQ_BG] = "enq_bg",
	[SP_STAT_ENQ_SHARED] = "enq_shared",
	[SP_STAT_DSP_LAT] = "dsp_lat",
	[SP_STAT_DSP_COMP] = "dsp_comp",
	[SP_STAT_DSP_CACHE] = "dsp_cache",
	[SP_STAT_DSP_SHARED] = "dsp_shared",
	[SP_STAT_RUN_NORMAL] = "run_normal",
	[SP_STAT_RUN_LAT] = "run_lat",
	[SP_STAT_RUN_COMP] = "run_comp",
	[SP_STAT_RUN_CACHE] = "run_cache",
	[SP_STAT_RUN_BG] = "run_bg",
	[SP_STAT_DIRECT_LAT] = "direct_lat",
	[SP_STAT_DIRECT_COMP] = "direct_comp",
	[SP_STAT_DIRECT_CACHE] = "direct_cache",
	[SP_STAT_DIRECT_NORMAL] = "direct_normal",
	[SP_STAT_PREEMPT_KICK] = "preempt_kick",
	[SP_STAT_PREEMPT_RATELIMITED] = "preempt_ratelimited",
	[SP_STAT_CLASSMAP_HIT] = "class_hit",
	[SP_STAT_CLASSMAP_MISS] = "class_miss",
	[SP_STAT_CLASSMAP_INVALID] = "class_invalid",
	[SP_STAT_CACHE_MIGRATED] = "cache_migrated",
	[SP_STAT_BG_VTIME_PENALTY] = "bg_vtime_penalty",
	[SP_STAT_DISPATCH_CALLS] = "dispatch_calls",
	[SP_STAT_ENQ_VTIME_COMP] = "enq_vtime_comp",
	[SP_STAT_ENQ_VTIME_CACHE] = "enq_vtime_cache",
	[SP_STAT_ENQ_VTIME_SHARED] = "enq_vtime_shared",
	[SP_STAT_CFG_ALIVE] = "cfg_alive",
	[SP_STAT_CFG_STALE] = "cfg_stale",
	[SP_STAT_DSQ_CACHE_TRY] = "dsq_cache_try",
	[SP_STAT_DSQ_CACHE_HIT] = "dsq_cache_hit",
	[SP_STAT_CLASSMAP_EXPIRED] = "class_expired",
};

static int libbpf_print_fn(enum libbpf_print_level level, const char *format,
			   va_list args)
{
	if (level == LIBBPF_DEBUG && !verbose)
		return 0;
	return vfprintf(stderr, format, args);
}

static void sig_handler(int sig)
{
	(void)sig;
	exit_req = 1;
}

static int ensure_pin_dir(void)
{
	if (mkdir("/sys/fs/bpf/schedpilot", 0755) && errno != EEXIST)
		return -errno;
	if (mkdir("/sys/fs/bpf/schedpilot/v1", 0755) && errno != EEXIST)
		return -errno;
	return 0;
}

static void pin_map_alias(int fd, const char *name)
{
	char path[256];

	if (fd < 0 || ensure_pin_dir() != 0)
		return;
	snprintf(path, sizeof(path), "%s/%s", pin_dir, name);
	unlink(path);
	if (bpf_obj_pin(fd, path) != 0 && errno != EEXIST)
		fprintf(stderr, "warn: failed to pin %s: %s\n", path,
			strerror(errno));
}

static void pin_schedpilot_maps(struct scx_schedpilot *skel)
{
	pin_map_alias(bpf_map__fd(skel->maps.sp_cfg), "cfg");
	pin_map_alias(bpf_map__fd(skel->maps.class_map), "class_map");
	pin_map_alias(bpf_map__fd(skel->maps.tg_stats), "tg_stats");
	pin_map_alias(bpf_map__fd(skel->maps.cpu_llc), "cpu_llc");
	pin_map_alias(bpf_map__fd(skel->maps.stats), "stats");
}

static void print_sched_ext_state(void)
{
	FILE *fp;
	char buf[256];

	fp = fopen("/sys/kernel/sched_ext/state", "r");
	if (fp) {
		if (fgets(buf, sizeof(buf), fp))
			printf("sched_ext.state=%s", buf);
		fclose(fp);
	} else {
		printf("sched_ext.state=unavailable\n");
	}
	fp = fopen("/sys/kernel/sched_ext/enable_seq", "r");
	if (fp) {
		if (fgets(buf, sizeof(buf), fp))
			printf("sched_ext.enable_seq=%s", buf);
		fclose(fp);
	}
}

static int open_pinned(const char *name)
{
	char path[256];

	snprintf(path, sizeof(path), "%s/%s", pin_dir, name);
	return bpf_obj_get(path);
}

static void init_cfg_defaults(int fd, __u32 mode)
{
	struct sp_cfg cfg = {
		.intf_version = SP_INTF_VERSION,
		.generation = 1,
		.mode = mode,
		.flags = SP_FLAG_CLASS_DSQ | SP_FLAG_PREEMPT |
			 SP_FLAG_LLC_AFFINITY | SP_FLAG_BG_CONTAIN,
		.heartbeat_seq = 0,
		.heartbeat_ns = 0,
		.lat_slice_ns = 1000000ULL,
		.comp_slice_ns = 4000000ULL,
		.cache_slice_ns = 8000000ULL,
		.bg_slice_ns = 2000000ULL,
		.preempt_thresh_ns = 500000ULL,
		.migrate_penalty_ns = 2000000ULL,
		.lat_vtime_pct = 100,
		.bg_vtime_pct = 200,
	};
	__u32 zero = 0;

	if (fd < 0)
		return;
	if (bpf_map_update_elem(fd, &zero, &cfg, BPF_ANY) != 0)
		fprintf(stderr, "warn: failed to init cfg: %s\n",
			strerror(errno));
}

static void print_cfg(void)
{
	int fd = open_pinned("cfg");
	struct sp_cfg cfg = {};
	__u32 zero = 0;

	if (fd < 0) {
		printf("cfg=missing\n");
		return;
	}
	if (bpf_map_lookup_elem(fd, &zero, &cfg) == 0) {
		time_t hb = (time_t)(cfg.heartbeat_ns / 1000000000ULL);
		printf("cfg mode=%u generation=%u flags=0x%x hb_seq=%u "
		       "hb_mono_s=%lld lat_slice=%llu comp_slice=%llu "
		       "cache_slice=%llu bg_slice=%llu preempt_thr=%llu "
		       "migrate_pen=%llu bg_vtime_pct=%u\n",
		       cfg.mode, cfg.generation, cfg.flags, cfg.heartbeat_seq,
		       (long long)hb, (unsigned long long)cfg.lat_slice_ns,
		       (unsigned long long)cfg.comp_slice_ns,
		       (unsigned long long)cfg.cache_slice_ns,
		       (unsigned long long)cfg.bg_slice_ns,
		       (unsigned long long)cfg.preempt_thresh_ns,
		       (unsigned long long)cfg.migrate_penalty_ns,
		       cfg.bg_vtime_pct);
	} else {
		printf("cfg=read_error\n");
	}
	close(fd);
}

static void print_stats(void)
{
	int fd = open_pinned("stats");
	int nr_cpus = libbpf_num_possible_cpus();
	__u64 *sums;
	__u32 idx;

	if (nr_cpus <= 0)
		nr_cpus = 1;
	if (fd < 0) {
		printf("stats=missing\n");
		return;
	}

	sums = calloc(SP_NR_STATS, sizeof(*sums));
	if (!sums) {
		close(fd);
		return;
	}

	__u64 *vals = calloc(nr_cpus, sizeof(*vals));

	for (idx = 0; idx < SP_NR_STATS; idx++) {
		int cpu;

		if (!vals)
			break;
		if (bpf_map_lookup_elem(fd, &idx, vals) != 0)
			continue;
		for (cpu = 0; cpu < nr_cpus; cpu++)
			sums[idx] += vals[cpu];
	}

	for (idx = 0; idx < SP_NR_STATS; idx++) {
		if (!stat_names[idx] || !sums[idx])
			continue;
		printf("%s=%llu ", stat_names[idx],
		       (unsigned long long)sums[idx]);
	}
	printf("\n");

	free(vals);
	free(sums);
	close(fd);
}

static int detach_running_scheduler(void)
{
	fprintf(stderr,
		"refuse unsafe global detach: use scripts/schedpilotctl.sh stop "
		"(it signals the recorded loader PID)\n");
	print_sched_ext_state();
	return 2;
}

static int write_pidfile(void)
{
	const char *paths[] = { "/run/schedpilot", "/tmp/schedpilot" };
	char path[256];
	int fd = -1;
	size_t i;

	for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		if (mkdir(paths[i], 0755) && errno != EEXIST)
			continue;
		snprintf(path, sizeof(path), "%s/scx_schedpilot.pid", paths[i]);
		fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
		if (fd >= 0)
			break;
	}
	if (fd < 0)
		return -errno;
	dprintf(fd, "%d\n", (int)getpid());
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	struct scx_schedpilot *skel;
	struct bpf_link *link;
	__u64 ecode;
	bool monitor = false;
	int i;

	libbpf_set_print(libbpf_print_fn);
	signal(SIGINT, sig_handler);
	signal(SIGTERM, sig_handler);

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
			mode_name = argv[++i];
			continue;
		}
		if (!strcmp(argv[i], "--status")) {
			status_only = true;
			continue;
		}
		if (!strcmp(argv[i], "--stats")) {
			stats_only = true;
			continue;
		}
		if (!strcmp(argv[i], "--detach")) {
			detach_only = true;
			continue;
		}
		if (!strcmp(argv[i], "--monitor") && i + 1 < argc) {
			monitor_interval = atof(argv[++i]);
			monitor = monitor_interval > 0;
			continue;
		}
		if (!strcmp(argv[i], "-v")) {
			verbose = true;
			continue;
		}
		if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			printf(help_fmt, basename(argv[0]));
			return 0;
		}
		fprintf(stderr, "unknown option: %s\n", argv[i]);
		fprintf(stderr, help_fmt, basename(argv[0]));
		return 1;
	}

	if (detach_only)
		return detach_running_scheduler();

	if (status_only) {
		print_sched_ext_state();
		print_cfg();
		return 0;
	}

	if (stats_only) {
		print_sched_ext_state();
		print_cfg();
		print_stats();
		return 0;
	}

	__u32 mode;
	if (!strcmp(mode_name, "basic"))
		mode = SP_MODE_BASIC;
	else if (!strcmp(mode_name, "class"))
		mode = SP_MODE_CLASS;
	else if (!strcmp(mode_name, "adaptive"))
		mode = SP_MODE_ADAPTIVE;
	else {
		fprintf(stderr, "invalid mode: %s\n", mode_name);
		return 1;
	}

	skel = SCX_OPS_OPEN(schedpilot_ops, scx_schedpilot);
	SCX_OPS_LOAD(skel, schedpilot_ops, scx_schedpilot, uei);
	init_cfg_defaults(bpf_map__fd(skel->maps.sp_cfg), mode);
	link = SCX_OPS_ATTACH(skel, schedpilot_ops, scx_schedpilot);
	pin_schedpilot_maps(skel);
	if (write_pidfile() != 0)
		fprintf(stderr, "warn: failed to write pidfile: %s\n",
			strerror(errno));

	printf("schedpilot loaded: mode=%s pin_dir=%s pid=%d\n", mode_name,
	       pin_dir, (int)getpid());
	fflush(stdout);

	while (!exit_req && !UEI_EXITED(skel, uei)) {
		if (monitor) {
			print_stats();
			fflush(stdout);
		}
		sleep(monitor ? (unsigned int)monitor_interval : 1);
	}

	bpf_link__destroy(link);
	ecode = UEI_REPORT(skel, uei);
	scx_schedpilot__destroy(skel);
	printf("schedpilot unloaded (ecode=0x%llx)\n",
	       (unsigned long long)ecode);
	return 0;
}
