// SPDX-License-Identifier: MIT
#include "classifier.hpp"

#include <algorithm>
#include <cmath>

namespace sp {

const char *class_name(uint32_t klass)
{
	switch (klass) {
	case SP_CLASS_LAT:
		return "L-SYNC";
	case SP_CLASS_COMP:
		return "C-COMPUTE";
	case SP_CLASS_CACHE:
		return "M-BOUND";
	case SP_CLASS_BG:
		return "BG";
	default:
		return "NORMAL";
	}
}

static double clamp01(double v)
{
	if (v < 0)
		return 0;
	if (v > 1)
		return 1;
	return v;
}

ClassDecision Classifier::update(uint32_t tgid, const Features &f)
{
	State &st = states_[tgid];
	ClassDecision d;
	const bool first_update = !st.primed;

	// EWMA over raw features; first observation primes the state.
	auto ewma = [&](double &target, double raw) {
		if (!st.primed)
			target = raw;
		else
			target = s_.alpha * raw + (1.0 - s_.alpha) * target;
	};

	if (f.sched_valid) {
		ewma(st.wake, f.wake_rate);
		ewma(st.run, f.avg_run_ns);
		ewma(st.delay, f.avg_delay_ns);
	}
	if (f.pmu_valid) {
		ewma(st.ipc, f.ipc);
		ewma(st.mpki, f.mpki);
	}
	st.primed = st.primed || f.sched_valid;

	uint32_t raw = SP_CLASS_NORMAL;
	double confidence = 0;
	std::string reason;

	/*
	 * L-SYNC is decided primarily by wakeup rate: a request-serving thread
	 * with sustained high wakeups is latency-sensitive regardless of its
	 * instantaneous IPC/MPKI (which are noisy under interference and used
	 * to cause M-BOUND flapping). IPC/MPKI only classify tasks that are
	 * not wakeup-driven.
	 *
	 * Event-driven servers (e.g. nginx workers under keep-alive) may wake
	 * at a lower rate than request-dispatched servers, so a secondary rule
	 * accepts moderate wakeups combined with short runs and low wait.
	 */
	bool lat = f.sched_valid &&
		   (st.wake >= s_.wake_hi ||
		    (s_.lat_moderate && st.wake >= s_.wake_hi / 5.0 &&
		     st.run <= s_.run_lo_ns &&
		     st.delay <= s_.delay_lo_ns * 4.0));

	if (lat) {
		double wake_margin = st.wake / std::max(1.0, s_.wake_hi / 5.0);
		double run_bonus = st.run <= s_.run_lo_ns ? 0.10 : 0.0;
		raw = SP_CLASS_LAT;
		confidence = clamp01(0.65 + 0.15 * std::log2(std::max(
						1.0, wake_margin)) +
				     run_bonus);
		reason = "high wake rate (latency-sensitive)";
	} else if (s_.use_pmu && f.pmu_valid) {
		if (st.ipc >= s_.ipc_hi && st.mpki <= s_.mpki_hi) {
			raw = SP_CLASS_COMP;
			double ipc_margin =
				st.ipc / std::max(0.01, s_.ipc_hi);
			double mpki_margin =
				(s_.mpki_hi + 1.0) / (st.mpki + 1.0);
			confidence = clamp01(0.60 + 0.15 * std::log2(std::max(
							1.0, ipc_margin)) +
					     0.12 * std::log2(std::max(
							1.0, mpki_margin)));
			reason = "high IPC + low LLC MPKI (compute bound)";
		} else {
			raw = SP_CLASS_CACHE;
			double ipc_margin =
				std::max(0.01, s_.ipc_hi) / std::max(0.01, st.ipc);
			double mpki_margin = st.mpki / std::max(0.01, s_.mpki_hi);
			confidence = clamp01(0.60 + 0.15 * std::log2(std::max(
							1.0, ipc_margin)) +
					     0.12 * std::log2(std::max(
							1.0, mpki_margin)));
			reason = "low IPC / high LLC MPKI (memory bound)";
		}
	} else {
		raw = SP_CLASS_NORMAL;
		confidence = 0.30;
		reason = s_.use_pmu ? "insufficient PMU/scheduling data"
				    : "PMU classification disabled";
	}

	// Hysteresis: a class change must hold for N consecutive cycles.
	if (first_update) {
		// first ever classification for this task: latch immediately
		st.current = raw;
		st.candidate = raw;
		st.streak = 0;
		d.changed = raw != SP_CLASS_NORMAL;
	} else if (raw == st.current) {
		st.candidate = raw;
		st.streak = 0;
	} else if (raw == st.candidate) {
		int need = s_.hysteresis_cycles;
		/* Asymmetric hysteresis: leaving L-SYNC needs stronger evidence
		 * so a few noisy samples cannot displace a latency-critical
		 * classification. */
		if (st.current == SP_CLASS_LAT && raw != SP_CLASS_LAT)
			need *= 2;
		st.streak++;
		if (st.streak >= need) {
			st.current = raw;
			st.streak = 0;
			d.changed = true;
		}
	} else {
		st.candidate = raw;
		st.streak = 1;
	}

	d.klass = st.current;
	d.confidence = confidence;
	d.reason = reason;
	return d;
}

} // namespace sp
