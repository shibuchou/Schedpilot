// SPDX-License-Identifier: MIT
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace sp {

// Scaled hardware counter deltas for one task group (TGID) over one sampling
// interval. All fields are 0 when valid == false.
struct PmuReading {
	bool valid = false;
	bool multiplexed = false;
	uint64_t cycles = 0;
	uint64_t instructions = 0;
	uint64_t cache_refs = 0;
	uint64_t cache_misses = 0;
};

class PmuSampler {
public:
	// Probes hardware PMU availability. Never throws.
	bool probe(std::string *reason);

	// Creates/refreshes per-thread event groups for a TGID.
	// Returns false and fills reason on hard failures; soft per-TID failures
	// are counted in skipped_threads().
	bool ensure_tgid(pid_t tgid, std::string *reason);
	void drop_tgid(pid_t tgid);
	void drop_all();

	// Reads and returns scaled deltas since the previous successful read.
	bool sample(pid_t tgid, PmuReading *out);

	bool available() const { return available_; }
	const std::string &unavailable_reason() const
	{
		return unavailable_reason_;
	}
	uint64_t skipped_threads() const { return skipped_threads_; }
	size_t tracked_tgids() const { return groups_.size(); }

private:
	struct Event {
		int fd = -1;
		uint64_t prev_raw = 0;
		bool primed = false;
	};
	struct Group {
		int nr_events = 0;
		bool primed = false;
		Event events[4];
		uint64_t prev_enabled = 0;
		uint64_t prev_running = 0;
	};

	bool open_group_for_tid(pid_t tid, Group *out, std::string *reason);
	void close_group(Group *g);
	static bool read_group(Group *g, uint64_t *values, uint64_t *enabled,
			       uint64_t *running);

	std::map<pid_t, std::map<pid_t, Group>> groups_;
	std::set<pid_t> failed_tgids_;
	bool available_ = false;
	std::string unavailable_reason_;
	uint64_t skipped_threads_ = 0;
};

} // namespace sp
