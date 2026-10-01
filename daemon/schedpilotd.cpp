// SPDX-License-Identifier: MIT
/*
 * schedpilotd - SchedPilot userspace control daemon.
 *
 * Slow control loop (default 100 ms) that:
 *   1. samples per-task-group hardware PMU counters (cycles, instructions,
 *      cache references/misses) with multiplex time_enabled/time_running
 *      scaling,
 *   2. reads wakeup / runtime / run-delay counters maintained by the
 *      scx_schedpilot BPF data plane,
 *   3. classifies tasks into L-SYNC / C-COMPUTE / M-BOUND with EWMA +
 *      hysteresis,
 *   4. writes classifications and (in adaptive mode) bounded policy knobs
 *      into pinned BPF maps with generation numbers and a heartbeat,
 *   5. records every classification, feature vector and policy update to an
 *      auditable JSONL log.
 */
#include <dirent.h>
#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "bpf_iface.hpp"
#include "classifier.hpp"
#include "config.hpp"
#include "intf.h"
#include "log.hpp"
#include "pmu_sampler.hpp"

namespace sp {

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int)
{
	g_stop = 1;
}

struct SampleTracker {
	bool primed = false;
	uint64_t wakeups = 0;
	uint64_t switches = 0;
	uint64_t runtime_ns = 0;
	uint64_t run_delay_ns = 0;
	uint64_t ts_ns = 0;
};

struct Target {
	uint32_t tgid = 0;
	std::string comm;
	bool bg = false;
	SampleTracker last;
	Features last_features;
};

static bool match_proc_name(const std::string &name,
			    const std::vector<std::string> &patterns)
{
	for (const auto &p : patterns) {
		if (p.empty())
			continue;
		if (name == p)
			return true;
		// /proc/<pid>/comm is truncated to 15 chars
		if (name.size() >= p.size() &&
		    name.compare(0, p.size(), p) == 0)
			return true;
		if (p.size() > name.size() &&
		    p.compare(0, name.size(), name) == 0)
			return true;
	}
	return false;
}

static std::string read_comm(uint32_t tgid)
{
	std::ifstream in("/proc/" + std::to_string(tgid) + "/comm");
	std::string s;
	if (!in)
		return "";
	std::getline(in, s);
	return trim(s);
}

static std::map<uint32_t, std::string>
scan_targets(const DaemonSettings &s)
{
	std::map<uint32_t, std::string> found;
	DIR *dir = opendir("/proc");
	if (!dir)
		return found;

	pid_t self = getpid();
	struct dirent *de;
	while ((de = readdir(dir)) != nullptr) {
		if (de->d_name[0] < '0' || de->d_name[0] > '9')
			continue;
		uint32_t tgid = (uint32_t)atoi(de->d_name);
		if ((pid_t)tgid == self)
			continue;
		std::string comm = read_comm(tgid);
		if (comm.empty())
			continue;
		if (match_proc_name(comm, s.excludes))
			continue;
		if (match_proc_name(comm, s.targets))
			found[tgid] = comm;
	}
	closedir(dir);
	return found;
}

// Build CPU -> LLC domain map from sysfs L3 shared_cpu_map bitmaps.
static std::map<uint32_t, uint32_t> build_cpu_llc_map(int nr_cpus)
{
	std::vector<int> parent(nr_cpus);
	for (int i = 0; i < nr_cpus; i++)
		parent[i] = i;

	std::function<int(int)> find = [&](int x) {
		while (parent[x] != x) {
			parent[x] = parent[parent[x]];
			x = parent[x];
		}
		return x;
	};
	auto unite = [&](int a, int b) {
		int ra = find(a), rb = find(b);
		if (ra != rb)
			parent[ra] = rb;
	};

	for (int cpu = 0; cpu < nr_cpus; cpu++) {
		char path[256];
		snprintf(path, sizeof(path),
			 "/sys/devices/system/cpu/cpu%d/cache/index3/"
			 "shared_cpu_map",
			 cpu);
		std::ifstream in(path);
		if (!in)
			continue;
		std::string line;
		std::getline(in, line);
		// Format: comma separated 32-bit hex groups, most significant
		// group first.
		std::vector<uint32_t> words;
		std::stringstream ss(line);
		std::string part;
		while (std::getline(ss, part, ',')) {
			try {
				words.push_back((uint32_t)std::stoul(
					trim(part), nullptr, 16));
			} catch (...) {
				words.clear();
				break;
			}
		}
		uint64_t bit = 0;
		for (auto it = words.rbegin(); it != words.rend(); ++it) {
			for (uint32_t b = 0; b < 32; b++, bit++) {
				if ((*it >> b) & 1u) {
					if ((int)bit < nr_cpus)
						unite(cpu, (int)bit);
				}
			}
		}
	}

	std::map<int, uint32_t> domain_ids;
	std::map<uint32_t, uint32_t> out;
	for (int cpu = 0; cpu < nr_cpus; cpu++) {
		int root = find(cpu);
		auto it = domain_ids.find(root);
		if (it == domain_ids.end()) {
			uint32_t id = (uint32_t)domain_ids.size();
			it = domain_ids.emplace(root, id).first;
		}
		out[(uint32_t)cpu] = it->second;
	}
	return out;
}

class JsonlLog {
public:
	bool open(const std::string &dir)
	{
		if (mkdir(dir.c_str(), 0755) && errno != EEXIST)
			return false;
		char stamp[32];
		time_t t = time(nullptr);
		struct tm tm;
		localtime_r(&t, &tm);
		strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &tm);
		std::string path =
			dir + "/schedpilotd-" + stamp + ".jsonl";
		f_ = fopen(path.c_str(), "a");
		if (!f_)
			return false;
		path_ = path;
		fprintf(f_, "{\"type\":\"start\",\"ts_real_ns\":%llu}\n",
			(unsigned long long)now_real_ns());
		fflush(f_);
		return true;
	}
	void line(const std::string &s)
	{
		if (!f_)
			return;
		fprintf(f_, "%s\n", s.c_str());
		fflush(f_);
	}
	const std::string &path() const { return path_; }
	void close()
	{
		if (f_) {
			fprintf(f_,
				"{\"type\":\"stop\",\"ts_real_ns\":%llu}\n",
				(unsigned long long)now_real_ns());
			fclose(f_);
			f_ = nullptr;
		}
	}

private:
	FILE *f_ = nullptr;
	std::string path_;
};

struct KnobAdjuster {
	uint64_t last_tick_ns = 0;
	uint64_t last_change_ns[3] = {0, 0, 0};
	int rr = 0;
};

static bool apply_knob(sp_cfg *cfg, KnobAdjuster *ka, JsonlLog *log,
		       const char *name, uint64_t oldv, uint64_t newv)
{
	(void)ka;
	if (oldv == newv)
		return false;
	cfg->generation++;
	log->line("{\"type\":\"policy\",\"ts_real_ns\":" +
		  std::to_string(now_real_ns()) + ",\"gen\":" +
		  std::to_string(cfg->generation) + ",\"knob\":\"" + name +
		  "\",\"old\":" + std::to_string(oldv) +
		  ",\"new\":" + std::to_string(newv) + "}");
	return true;
}

static void policy_adjust(BpfIface &iface, sp_cfg *cfg, JsonlLog *log,
			  const DaemonSettings &s, const Features &lat_agg,
			  const Features &cache_agg, int lat_n, int cache_n,
			  uint64_t cache_migrations_per_s, bool dry_run)
{
	KnobAdjuster *ka = nullptr;
	static KnobAdjuster ka_storage;
	ka = &ka_storage;

	uint64_t now = now_mono_ns();
	if (ka->last_tick_ns == 0) {
		ka->last_tick_ns = now;
		return;
	}
	if (now - ka->last_tick_ns < 1000000000ULL) // 1 Hz policy tick
		return;
	ka->last_tick_ns = now;

	__u64 *target = nullptr;
	uint64_t oldv = 0, newv = 0;

	// Round-robin: at most one knob change per tick.
	switch (ka->rr++ % 3) {
	case 0: // LAT slice follows run delay
		if (lat_n > 0) {
			target = &cfg->lat_slice_ns;
			oldv = cfg->lat_slice_ns;
			newv = oldv;
			if (lat_agg.avg_delay_ns > s.delay_lo_ns * 2.0 &&
			    oldv > 300000ULL)
				newv = std::max<uint64_t>(300000ULL,
							  oldv * 85 / 100);
			else if (lat_agg.avg_delay_ns < s.delay_lo_ns * 0.5 &&
				 oldv < 1500000ULL)
				newv = std::min<uint64_t>(1500000ULL,
							  oldv * 115 / 100);
		}
		break;
	case 1: // CACHE slice follows LLC MPKI; decays to default when idle
		target = &cfg->cache_slice_ns;
		oldv = cfg->cache_slice_ns;
		newv = oldv;
		if (cache_n > 0) {
			if (cache_agg.mpki > s.mpki_hi &&
			    oldv < 10000000ULL)
				newv = std::min<uint64_t>(10000000ULL,
							  oldv * 125 / 100);
			else if (cache_agg.mpki < s.mpki_hi / 2.0 &&
				 oldv > 2000000ULL)
				newv = std::max<uint64_t>(2000000ULL,
							  oldv * 90 / 100);
		} else if (oldv > 8000000ULL) {
			newv = std::max<uint64_t>(8000000ULL,
						  oldv * 90 / 100);
		}
		break;
	default: // migration penalty follows cache migrations; decays to default
		target = &cfg->migrate_penalty_ns;
		oldv = cfg->migrate_penalty_ns;
		newv = oldv;
		if (cache_migrations_per_s > 100 && oldv < 6000000ULL)
			newv = std::min<uint64_t>(6000000ULL,
						  oldv * 150 / 100);
		else if (cache_migrations_per_s == 0 && oldv > 2000000ULL)
			newv = std::max<uint64_t>(2000000ULL,
						  oldv * 80 / 100);
		break;
	}

	if (!target || oldv == newv)
		return;

	*target = newv;
	apply_knob(cfg, ka, log, "knob", oldv, newv);
	if (!dry_run)
		iface.cfg_set(*cfg);
}

static void print_usage(const char *prog)
{
	printf("schedpilotd - SchedPilot control daemon\n\n"
	       "Usage: %s [options]\n\n"
	       "  --config FILE      Config file (default: configs/schedpilot.conf)\n"
	       "  --set-mode MODE    One-shot: basic|class|adaptive, then exit\n"
	       "  --ablation N=0|1   llc_affinity|bg_contain|preempt|pmu_classify\n"
	       "  --policy on|off    Adaptive knob control (default: on)\n"
	       "  --duration SEC     Exit automatically after SEC seconds\n"
	       "  --dry-run          Do not write BPF maps (logging only)\n"
	       "  --dump-cfg         Print current BPF cfg as JSON, then exit\n"
	       "  --status           Print daemon/scheduler/PMU status, then exit\n"
	       "  --verbose          Verbose logging\n"
	       "  --help             This help\n",
	       prog);
}

} // namespace sp

using namespace sp;

int main(int argc, char **argv)
{
	std::string config_path = "configs/schedpilot.conf";
	std::string log_dir_override;
	std::string set_mode;
	std::map<std::string, int> ablations;
	bool dump_cfg = false, status_only = false, dry_run = false;
	int duration_s = 0;
	int policy_override = -1; // -1 unset, 0 off, 1 on

	static struct option opts[] = {
		{ "config", required_argument, nullptr, 1000 },
		{ "set-mode", required_argument, nullptr, 1001 },
		{ "ablation", required_argument, nullptr, 1002 },
		{ "policy", required_argument, nullptr, 1003 },
		{ "duration", required_argument, nullptr, 1004 },
		{ "dry-run", no_argument, nullptr, 1005 },
		{ "dump-cfg", no_argument, nullptr, 1006 },
		{ "status", no_argument, nullptr, 1007 },
		{ "verbose", no_argument, nullptr, 1008 },
		{ "help", no_argument, nullptr, 1009 },
		{ "log-dir", required_argument, nullptr, 1010 },
		{ nullptr, 0, nullptr, 0 },
	};

	int opt;
	while ((opt = getopt_long(argc, argv, "", opts, nullptr)) != -1) {
		switch (opt) {
		case 1000:
			config_path = optarg;
			break;
		case 1001:
			set_mode = optarg;
			break;
		case 1002: {
			std::string a = optarg;
			auto eq = a.find('=');
			if (eq == std::string::npos) {
				fprintf(stderr, "bad --ablation: %s\n", optarg);
				return 1;
			}
			ablations[a.substr(0, eq)] = atoi(a.substr(eq + 1).c_str());
			break;
		}
		case 1003:
			policy_override = !strcmp(optarg, "on") ? 1 : 0;
			break;
		case 1004:
			duration_s = atoi(optarg);
			break;
		case 1005:
			dry_run = true;
			break;
		case 1006:
			dump_cfg = true;
			break;
		case 1007:
			status_only = true;
			break;
		case 1008:
			set_verbose(true);
			break;
		case 1010:
			log_dir_override = optarg;
			break;
		case 1009:
		default:
			print_usage(argv[0]);
			return opt == 1009 ? 0 : 1;
		}
	}

	DaemonSettings settings;
	try {
		Config cfg_file = Config::load(config_path);
		settings = DaemonSettings::from_config(cfg_file);
	} catch (const std::exception &e) {
		log(LogLevel::Error, "%s", e.what());
		return 1;
	}

	settings.dry_run = dry_run;
	settings.duration_s = duration_s;
	if (!log_dir_override.empty())
		settings.log_dir = log_dir_override;
	if (policy_override >= 0)
		settings.policy_enabled = policy_override == 1;
	for (auto &kv : ablations) {
		if (kv.first == "llc_affinity")
			settings.llc_affinity = kv.second != 0;
		else if (kv.first == "bg_contain")
			settings.bg_contain = kv.second != 0;
		else if (kv.first == "preempt")
			settings.preempt = kv.second != 0;
		else if (kv.first == "pmu_classify")
			settings.classify_pmu = kv.second != 0;
		else
			log(LogLevel::Warn, "unknown ablation: %s",
			    kv.first.c_str());
	}

	BpfIface iface;
	std::string err;
	if (!iface.open_maps(&err)) {
		log(LogLevel::Error, "%s", err.c_str());
		return 1;
	}

	sp_cfg cfg{};
	if (!iface.cfg_get(&cfg)) {
		log(LogLevel::Error, "cannot read cfg map");
		return 1;
	}

	if (!set_mode.empty()) {
		if (set_mode == "basic")
			cfg.mode = SP_MODE_BASIC;
		else if (set_mode == "class")
			cfg.mode = SP_MODE_CLASS;
		else if (set_mode == "adaptive")
			cfg.mode = SP_MODE_ADAPTIVE;
		else {
			fprintf(stderr, "invalid mode: %s\n", set_mode.c_str());
			return 1;
		}
		cfg.generation++;
		if (iface.cfg_set(cfg)) {
			printf("{\"mode\":\"%s\",\"generation\":%u}\n",
			       set_mode.c_str(), cfg.generation);
			return 0;
		}
		fprintf(stderr, "failed to write cfg\n");
		return 1;
	}

	if (dump_cfg) {
		printf("{\"mode\":%u,\"generation\":%u,\"flags\":%u,"
		       "\"heartbeat_seq\":%u,\"heartbeat_ns\":%llu,"
		       "\"lat_slice_ns\":%llu,\"comp_slice_ns\":%llu,"
		       "\"cache_slice_ns\":%llu,\"bg_slice_ns\":%llu,"
		       "\"preempt_thresh_ns\":%llu,\"migrate_penalty_ns\":%llu,"
		       "\"bg_vtime_pct\":%u}\n",
		       cfg.mode, cfg.generation, cfg.flags, cfg.heartbeat_seq,
		       (unsigned long long)cfg.heartbeat_ns,
		       (unsigned long long)cfg.lat_slice_ns,
		       (unsigned long long)cfg.comp_slice_ns,
		       (unsigned long long)cfg.cache_slice_ns,
		       (unsigned long long)cfg.bg_slice_ns,
		       (unsigned long long)cfg.preempt_thresh_ns,
		       (unsigned long long)cfg.migrate_penalty_ns,
		       cfg.bg_vtime_pct);
		return 0;
	}

	PmuSampler pmu;
	std::string pmu_reason;
	bool pmu_ok = pmu.probe(&pmu_reason);
	if (!pmu_ok)
		log(LogLevel::Warn,
		    "PMU unavailable (%s); degrading to scheduling-only features",
		    pmu_reason.c_str());
	else
		log(LogLevel::Info, "PMU available");

	auto llc_map = build_cpu_llc_map(iface.nr_cpus());
	if (!dry_run) {
		for (auto &kv : llc_map)
			iface.cpu_llc_set(kv.first, kv.second);
	}

	if (status_only) {
		uint32_t class_count = 0;
		iface.class_count(&class_count);
		std::vector<uint64_t> stats;
		iface.stats_read(&stats);
		uint64_t hb_age_s =
			cfg.heartbeat_ns
				? (now_mono_ns() - cfg.heartbeat_ns) / 1000000000ULL
				: 0;
		printf("{\"mode\":%u,\"generation\":%u,\"flags\":%u,"
		       "\"heartbeat_age_s\":%llu,\"class_map_entries\":%u,"
		       "\"pmu_available\":%s,\"pmu_reason\":\"%s\","
		       "\"dispatch_calls\":%llu,\"enq_lat\":%llu,"
		       "\"enq_comp\":%llu,\"enq_cache\":%llu}\n",
		       cfg.mode, cfg.generation, cfg.flags,
		       (unsigned long long)hb_age_s, class_count,
		       pmu_ok ? "true" : "false",
		       json_escape(pmu_reason).c_str(),
		       (unsigned long long)(stats.size() > SP_STAT_DISPATCH_CALLS
						    ? stats[SP_STAT_DISPATCH_CALLS]
						    : 0),
		       (unsigned long long)(stats.size() > SP_STAT_ENQ_LAT
						    ? stats[SP_STAT_ENQ_LAT]
						    : 0),
		       (unsigned long long)(stats.size() > SP_STAT_ENQ_COMP
						    ? stats[SP_STAT_ENQ_COMP]
						    : 0),
		       (unsigned long long)(stats.size() > SP_STAT_ENQ_CACHE
						    ? stats[SP_STAT_ENQ_CACHE]
						    : 0));
		return 0;
	}

	// Apply ablated flags and announce control intent.
	cfg.flags &= ~(SP_FLAG_LLC_AFFINITY | SP_FLAG_BG_CONTAIN |
		       SP_FLAG_PREEMPT | SP_FLAG_CLASSIFY);
	if (settings.llc_affinity)
		cfg.flags |= SP_FLAG_LLC_AFFINITY;
	if (settings.bg_contain)
		cfg.flags |= SP_FLAG_BG_CONTAIN;
	if (settings.preempt)
		cfg.flags |= SP_FLAG_PREEMPT;
	if (settings.policy_enabled)
		cfg.flags |= SP_FLAG_CLASSIFY;
	if (!dry_run) {
		cfg.generation++;
		if (!iface.cfg_set(cfg)) {
			log(LogLevel::Error, "failed to apply startup cfg");
			return 1;
		}
	}

	JsonlLog log_file;
	if (!log_file.open(settings.log_dir)) {
		log(LogLevel::Error, "cannot open log dir %s",
		    settings.log_dir.c_str());
		return 1;
	}

	log(LogLevel::Info,
	    "schedpilotd started: config=%s mode=%u policy=%s pmu=%s "
	    "log=%s",
	    config_path.c_str(), cfg.mode,
	    settings.policy_enabled ? "on" : "off", pmu_ok ? "on" : "off",
	    log_file.path().c_str());

	Classifier classifier(ClassifierSettings{
		settings.alpha, settings.wake_hi, settings.run_lo_ns,
		settings.delay_lo_ns, settings.ipc_hi, settings.mpki_hi,
		settings.hysteresis_cycles, settings.classify_pmu });

	std::map<uint32_t, Target> targets;
	uint64_t start_ns = now_mono_ns();
	uint64_t last_scan_ns = 0;
	uint64_t last_stats_ns = 0;
	std::vector<uint64_t> prev_stats;
	bool warned_dry_run = false;
	int write_failures = 0;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	while (!g_stop) {
		uint64_t now = now_mono_ns();
		uint64_t interval_ns = (uint64_t)settings.interval_ms * 1000000ULL;
		double dt_s = (double)interval_ns / 1e9;

		if (settings.duration_s > 0 &&
		    now - start_ns >= (uint64_t)settings.duration_s * 1000000000ULL)
			break;

		// Rescan target processes once per second.
		if (now - last_scan_ns >= 1000000000ULL) {
			last_scan_ns = now;
			auto found = scan_targets(settings);
			std::set<uint32_t> live;
			for (auto &kv : found)
				live.insert(kv.first);
			for (auto it = targets.begin(); it != targets.end();) {
				if (!live.count(it->first)) {
					classifier.forget(it->first);
					if (!dry_run)
						iface.class_del(it->first);
					it = targets.erase(it);
				} else {
					++it;
				}
			}
			for (auto &kv : found) {
				if (!targets.count(kv.first)) {
					Target t;
					t.tgid = kv.first;
					t.comm = kv.second;
					t.bg = match_proc_name(kv.second, settings.bg);
					targets.emplace(kv.first, t);
					log(LogLevel::Info,
					    "tracking %s tgid=%u%s",
					    t.comm.c_str(), t.tgid,
					    t.bg ? " (BG, external)" : "");
					if (!dry_run && pmu_ok)
						pmu.ensure_tgid(t.tgid, nullptr);
				}
			}
		}

		// Aggregated features for the policy tick.
		Features lat_agg, cache_agg;
		int lat_n = 0, cache_n = 0;
		uint64_t lat_delay_sum = 0, lat_delay_cnt = 0;
		uint64_t cache_mpki_cnt = 0;
		double cache_mpki_sum = 0;

		for (auto &kv : targets) {
			Target &t = kv.second;
			Features f;
			sp_tg_stats bstats{};
			bool have_sched = iface.tg_stats_get(t.tgid, &bstats);

			if (have_sched) {
				if (t.last.primed && bstats.switches >= t.last.switches) {
					uint64_t d_wake = bstats.wakeups - t.last.wakeups;
					uint64_t d_sw = bstats.switches - t.last.switches;
					uint64_t d_rt = bstats.runtime_ns - t.last.runtime_ns;
					uint64_t d_dl = bstats.run_delay_ns - t.last.run_delay_ns;
					uint64_t d_ts = bstats.last_update_ns > t.last.ts_ns
							  ? bstats.last_update_ns - t.last.ts_ns
							  : (now - t.last.ts_ns);
					double dts = d_ts ? (double)d_ts / 1e9 : dt_s;
					if (dts > 0) {
						f.wake_rate = (double)d_wake / dts;
						if (d_sw > 0) {
							f.avg_run_ns = (double)d_rt / d_sw;
							f.avg_delay_ns = (double)d_dl / d_sw;
						}
						f.sched_valid = true;
					}
				}
				t.last.primed = true;
				t.last.wakeups = bstats.wakeups;
				t.last.switches = bstats.switches;
				t.last.runtime_ns = bstats.runtime_ns;
				t.last.run_delay_ns = bstats.run_delay_ns;
				t.last.ts_ns = bstats.last_update_ns ? bstats.last_update_ns : now;
			}

			if (pmu_ok && !t.bg) {
				PmuReading r;
				if (pmu.sample(t.tgid, &r) && r.valid) {
					if (r.cycles > 0) {
						f.ipc = (double)r.instructions / r.cycles;
						f.pmu_valid = true;
					}
					if (r.instructions > 0) {
						f.mpki = (double)r.cache_misses * 1000.0 /
							 r.instructions;
						f.pmu_valid = true;
					}
					f.pmu_multiplexed = r.multiplexed;
				}
			}
			t.last_features = f;

			if (t.bg) {
				if (!dry_run && cfg.mode != SP_MODE_BASIC) {
					sp_task_class tc{};
					tc.klass = SP_CLASS_BG;
					tc.confidence = 1000;
					tc.updated_ns = now_real_ns();
					tc.source = SP_SRC_EXTERN;
					if (!iface.class_set(t.tgid, tc))
						write_failures++;
					else
						write_failures = 0;
				}
				log_file.line(
					"{\"type\":\"sample\",\"ts_real_ns\":" +
					std::to_string(now_real_ns()) +
					",\"tgid\":" + std::to_string(t.tgid) +
					",\"comm\":\"" + json_escape(t.comm) +
					"\",\"class\":\"BG\",\"confidence\":1.0,"
					"\"source\":\"external\",\"bg\":true}");
				continue;
			}

			ClassDecision d = classifier.update(t.tgid, f);
			if (!dry_run && cfg.mode != SP_MODE_BASIC &&
			    (d.changed || d.klass != SP_CLASS_NORMAL)) {
				sp_task_class tc{};
				tc.klass = d.klass;
				tc.confidence =
					(uint32_t)(d.confidence * 1000.0);
				tc.updated_ns = now_real_ns();
				tc.source = SP_SRC_RULES;
				if (!iface.class_set(t.tgid, tc))
					write_failures++;
				else
					write_failures = 0;
			}

			char buf[1024];
			snprintf(
				buf, sizeof(buf),
				"{\"type\":\"sample\",\"ts_real_ns\":%llu,"
				"\"tgid\":%u,\"comm\":\"%s\",\"class\":\"%s\","
				"\"confidence\":%.3f,\"changed\":%s,"
				"\"features\":{\"sched_valid\":%s,"
				"\"pmu_valid\":%s,\"pmu_multiplexed\":%s,"
				"\"wake_rate\":%.2f,\"avg_run_ns\":%.0f,"
				"\"avg_delay_ns\":%.0f,\"ipc\":%.4f,"
				"\"mpki\":%.4f},\"reason\":\"%s\"}",
				(unsigned long long)now_real_ns(), t.tgid,
				json_escape(t.comm).c_str(),
				class_name(d.klass), d.confidence,
				d.changed ? "true" : "false",
				f.sched_valid ? "true" : "false",
				f.pmu_valid ? "true" : "false",
				f.pmu_multiplexed ? "true" : "false",
				f.wake_rate, f.avg_run_ns, f.avg_delay_ns,
				f.ipc, f.mpki, json_escape(d.reason).c_str());
			log_file.line(buf);

			if (d.klass == SP_CLASS_LAT && f.sched_valid) {
				lat_agg.avg_delay_ns += f.avg_delay_ns;
				lat_delay_sum += (uint64_t)f.avg_delay_ns;
				lat_delay_cnt++;
				lat_n++;
			}
			if (d.klass == SP_CLASS_CACHE && f.pmu_valid) {
				cache_mpki_sum += f.mpki;
				cache_mpki_cnt++;
				cache_n++;
			}
		}
		if (lat_delay_cnt)
			lat_agg.avg_delay_ns = (double)lat_delay_sum / lat_delay_cnt;
		if (cache_mpki_cnt)
			cache_agg.mpki = cache_mpki_sum / cache_mpki_cnt;

		// Scheduler stats deltas for overhead and migration telemetry.
		std::vector<uint64_t> stats;
		uint64_t cache_migrations_per_s = 0;
		if (iface.stats_read(&stats)) {
			if (!prev_stats.empty() && stats.size() >= SP_NR_STATS) {
				uint64_t d_mig = stats[SP_STAT_CACHE_MIGRATED] -
						 prev_stats[SP_STAT_CACHE_MIGRATED];
				uint64_t d_calls =
					stats[SP_STAT_DISPATCH_CALLS] -
					prev_stats[SP_STAT_DISPATCH_CALLS];
				cache_migrations_per_s =
					(uint64_t)(d_mig / std::max(1e-9, dt_s));
				(void)d_calls;
			}
			prev_stats = stats;
		}
		(void)last_stats_ns;

		// Adaptive policy + heartbeat (single cfg write per cycle).
		if (cfg.mode == SP_MODE_ADAPTIVE && settings.policy_enabled)
			policy_adjust(iface, &cfg, &log_file, settings, lat_agg,
				      cache_agg, lat_n, cache_n,
				      cache_migrations_per_s, dry_run);
		cfg.heartbeat_seq++;
		cfg.heartbeat_ns = now_mono_ns();
		if (!dry_run) {
			if (iface.cfg_set(cfg))
				write_failures = 0;
			else if (++write_failures > 50) {
				log(LogLevel::Error,
				    "persistent cfg write failures; exiting");
				break;
			}
		} else if (!warned_dry_run) {
			warned_dry_run = true;
			log(LogLevel::Warn,
			    "dry-run: not writing BPF maps");
		}

		usleep((useconds_t)(interval_ns / 1000));
	}

	log_file.close();
	log(LogLevel::Info, "schedpilotd stopped");
	return 0;
}
