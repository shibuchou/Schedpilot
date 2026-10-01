// SPDX-License-Identifier: MIT
#pragma once

#include <cstdint>
#include <map>
#include <string>

#include "intf.h"

namespace sp {

struct Features {
	bool sched_valid = false;
	bool pmu_valid = false;
	bool pmu_multiplexed = false;
	double wake_rate = 0;    // wakeups / second
	double avg_run_ns = 0;   // runtime / switch
	double avg_delay_ns = 0; // run delay / switch
	double ipc = 0;          // instructions / cycles
	double mpki = 0;         // cache misses / 1000 instructions
};

struct ClassDecision {
	uint32_t klass = SP_CLASS_NORMAL;
	double confidence = 0; // 0..1
	bool changed = false;
	std::string reason;
};

struct ClassifierSettings {
	double alpha = 0.3;
	double wake_hi = 500.0;
	double run_lo_ns = 2000000.0;
	double delay_lo_ns = 500000.0;
	double ipc_hi = 1.2;
	double mpki_hi = 10.0;
	int hysteresis_cycles = 5;
	bool use_pmu = true;
};

class Classifier {
public:
	explicit Classifier(const ClassifierSettings &s) : s_(s) {}

	ClassDecision update(uint32_t tgid, const Features &f);
	void forget(uint32_t tgid) { states_.erase(tgid); }

private:
	struct State {
		bool primed = false;
		double wake = 0, run = 0, delay = 0, ipc = 0, mpki = 0;
		uint32_t current = SP_CLASS_NORMAL;
		uint32_t candidate = SP_CLASS_NORMAL;
		int streak = 0;
	};

	ClassifierSettings s_;
	std::map<uint32_t, State> states_;
};

const char *class_name(uint32_t klass);

} // namespace sp
