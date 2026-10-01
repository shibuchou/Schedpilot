// SPDX-License-Identifier: MIT
#include "pmu_sampler.hpp"

#include <asm/unistd.h>
#include <dirent.h>
#include <errno.h>
#include <linux/perf_event.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "log.hpp"

namespace sp {

static int perf_event_open_wrap(struct perf_event_attr *attr, pid_t pid,
				int cpu, int group_fd, unsigned long flags)
{
	return (int)syscall(__NR_perf_event_open, attr, pid, cpu, group_fd,
			    flags);
}

static bool fill_attr(struct perf_event_attr *pe, uint64_t config)
{
	memset(pe, 0, sizeof(*pe));
	pe->type = PERF_TYPE_HARDWARE;
	pe->size = sizeof(*pe);
	pe->config = config;
	pe->disabled = 0;
	pe->inherit = 1;
	pe->exclude_hv = 1;
	pe->read_format = PERF_FORMAT_GROUP | PERF_FORMAT_TOTAL_TIME_ENABLED |
			  PERF_FORMAT_TOTAL_TIME_RUNNING;
	return true;
}

bool PmuSampler::probe(std::string *reason)
{
	struct perf_event_attr pe;
	int fd;

	fill_attr(&pe, PERF_COUNT_HW_CPU_CYCLES);
	// Probe with the calling thread only; the group is closed immediately.
	pe.inherit = 0;
	fd = perf_event_open_wrap(&pe, 0 /* self */, -1, -1, 0);
	if (fd < 0) {
		available_ = false;
		unavailable_reason_ = std::string("perf_event_open failed: ") +
				      strerror(errno);
		if (reason)
			*reason = unavailable_reason_;
		return false;
	}
	close(fd);
	available_ = true;
	unavailable_reason_.clear();
	return true;
}

bool PmuSampler::open_group_for_tid(pid_t tid, Group *out, std::string *reason)
{
	static const uint64_t configs[4] = {
		PERF_COUNT_HW_CPU_CYCLES,
		PERF_COUNT_HW_INSTRUCTIONS,
		PERF_COUNT_HW_CACHE_REFERENCES,
		PERF_COUNT_HW_CACHE_MISSES,
	};

	*out = Group{};
	out->nr_events = 4;

	for (int i = 0; i < 4; i++) {
		struct perf_event_attr pe;
		int fd;

		fill_attr(&pe, configs[i]);
		fd = perf_event_open_wrap(&pe, tid, -1,
					  i == 0 ? -1 : out->events[0].fd, 0);
		if (fd < 0) {
			if (reason) {
				*reason = std::string("perf_event_open(tid=") +
					  std::to_string(tid) + ") failed: " +
					  strerror(errno);
			}
			close_group(out);
			return false;
		}
		out->events[i].fd = fd;
	}
	return true;
}

void PmuSampler::close_group(Group *g)
{
	for (int i = 0; i < 4; i++) {
		if (g->events[i].fd >= 0) {
			close(g->events[i].fd);
			g->events[i].fd = -1;
		}
	}
}

void PmuSampler::drop_tgid(pid_t tgid)
{
	auto it = groups_.find(tgid);
	if (it == groups_.end())
		return;
	for (auto &kv : it->second)
		close_group(&kv.second);
	groups_.erase(it);
}

void PmuSampler::drop_all()
{
	for (auto &kv : groups_) {
		for (auto &inner : kv.second)
			close_group(&inner.second);
	}
	groups_.clear();
}

bool PmuSampler::ensure_tgid(pid_t tgid, std::string *reason)
{
	if (!available_)
		return false;

	// Enumerate current threads.
	std::string task_dir = "/proc/" + std::to_string(tgid) + "/task";
	DIR *dir = opendir(task_dir.c_str());
	if (!dir) {
		drop_tgid(tgid);
		return false;
	}

	std::set<pid_t> live;
	struct dirent *de;
	while ((de = readdir(dir)) != nullptr) {
		if (de->d_name[0] == '.')
			continue;
		pid_t tid = (pid_t)atoi(de->d_name);
		if (tid > 0)
			live.insert(tid);
	}
	closedir(dir);

	auto &group = groups_[tgid];
	for (pid_t tid : live) {
		if (group.count(tid))
			continue;
		Group g;
		std::string err;
		if (!open_group_for_tid(tid, &g, &err)) {
			skipped_threads_++;
			log(LogLevel::Warn, "pmu: %s", err.c_str());
			continue;
		}
		group.emplace(tid, g);
	}
	for (auto it = group.begin(); it != group.end();) {
		if (!live.count(it->first)) {
			close_group(&it->second);
			it = group.erase(it);
		} else {
			++it;
		}
	}
	if (group.empty()) {
		groups_.erase(tgid);
		if (reason)
			*reason = "no threads with PMU events";
		return false;
	}
	return true;
}

// read_format: u64 nr; u64 time_enabled; u64 time_running; u64 values[nr];
bool PmuSampler::read_group(Group *g, uint64_t *values, uint64_t *enabled,
			    uint64_t *running)
{
	uint64_t buf[3 + 4];

	ssize_t n = read(g->events[0].fd, buf, sizeof(buf));
	if (n < (ssize_t)(3 * sizeof(uint64_t)) + (ssize_t)sizeof(uint64_t))
		return false;
	uint64_t nr = buf[0];
	if (nr > 4)
		nr = 4;
	for (uint64_t i = 0; i < nr; i++)
		values[i] = buf[3 + i];
	*enabled = buf[1];
	*running = buf[2];
	return true;
}

bool PmuSampler::sample(pid_t tgid, PmuReading *out)
{
	*out = PmuReading{};
	if (!available_)
		return false;

	auto it = groups_.find(tgid);
	if (it == groups_.end())
		return false;

	uint64_t sum[4] = {0, 0, 0, 0};
	bool any = false;
	bool multiplexed = false;

	for (auto &kv : it->second) {
		Group &g = kv.second;
		uint64_t values[4] = {0, 0, 0, 0};
		uint64_t enabled = 0, running = 0;

		if (!read_group(&g, values, &enabled, &running)) {
			log(LogLevel::Warn,
			    "pmu: read failed tgid=%d tid=%d, dropping group",
			    (int)tgid, (int)kv.first);
			close_group(&g);
			continue;
		}

		if (!g.primed) {
			for (int i = 0; i < 4; i++)
				g.events[i].prev_raw = values[i];
			g.prev_enabled = enabled;
			g.prev_running = running;
			g.primed = true;
			continue;
		}

		uint64_t d_enabled = enabled - g.prev_enabled;
		uint64_t d_running = running - g.prev_running;
		for (int i = 0; i < 4; i++) {
			uint64_t d_raw = values[i] - g.events[i].prev_raw;
			g.events[i].prev_raw = values[i];
			uint64_t scaled = d_raw;
			if (d_running > 0 && d_running < d_enabled) {
				// Multiplex scaling: raw * enabled / running.
				unsigned __int128 tmp =
					(unsigned __int128)d_raw * d_enabled;
				scaled = (uint64_t)(tmp / d_running);
				multiplexed = true;
			}
			sum[i] += scaled;
			any = true;
		}
		g.prev_enabled = enabled;
		g.prev_running = running;
	}

	if (!any)
		return false;

	out->valid = true;
	out->multiplexed = multiplexed;
	out->cycles = sum[0];
	out->instructions = sum[1];
	out->cache_refs = sum[2];
	out->cache_misses = sum[3];
	return true;
}

} // namespace sp
