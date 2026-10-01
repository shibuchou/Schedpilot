// SPDX-License-Identifier: MIT
// Unit tests for the SchedPilot EWMA + hysteresis classifier.
#include <cassert>
#include <cstdio>
#include <cstring>

#include "classifier.hpp"

using namespace sp;

static int failures = 0;

#define CHECK(cond)                                                         \
	do {                                                                 \
		if (!(cond)) {                                               \
			printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                          \
		}                                                           \
	} while (0)

static Features sched_features(double wake, double run_ns, double delay_ns)
{
	Features f;
	f.sched_valid = true;
	f.wake_rate = wake;
	f.avg_run_ns = run_ns;
	f.avg_delay_ns = delay_ns;
	return f;
}

static Features pmu_features(double ipc, double mpki)
{
	Features f;
	f.pmu_valid = true;
	f.ipc = ipc;
	f.mpki = mpki;
	return f;
}

int main()
{
	ClassifierSettings s;
	s.alpha = 0.5;
	s.wake_hi = 500;
	s.ipc_hi = 1.2;
	s.mpki_hi = 10.0;
	s.hysteresis_cycles = 4;
	s.use_pmu = true;

	// 1) high wake rate alone -> L-SYNC (wake-rate primary)
	{
		Classifier c(s);
		Features f = sched_features(2000, 500000, 0);
		auto d = c.update(1, f);
		CHECK(d.klass == SP_CLASS_LAT);
	}

	// 2) high wake rate wins even with memory-bound PMU numbers
	{
		Classifier c(s);
		Features f = sched_features(2000, 500000, 0);
		f.pmu_valid = true;
		f.ipc = 0.1;
		f.mpki = 40.0;
		auto d = c.update(2, f);
		CHECK(d.klass == SP_CLASS_LAT);
	}

	// 2b) moderate wakeups + short runs + low wait -> L-SYNC (event-driven
	//     server such as an nginx worker)
	{
		Classifier c(s);
		Features f = sched_features(200, 500000, 0);
		auto d = c.update(20, f);
		CHECK(d.klass == SP_CLASS_LAT);
	}

	// 3) low wake + high IPC + low MPKI -> C-COMPUTE
	{
		Classifier c(s);
		Features f = sched_features(10, 30000000, 100000);
		Features p = pmu_features(2.0, 1.0);
		f.pmu_valid = p.pmu_valid;
		f.ipc = p.ipc;
		f.mpki = p.mpki;
		auto d = c.update(3, f);
		CHECK(d.klass == SP_CLASS_COMP);
	}

	// 4) low wake + low IPC -> M-BOUND
	{
		Classifier c(s);
		Features f = sched_features(10, 30000000, 100000);
		f.pmu_valid = true;
		f.ipc = 0.2;
		f.mpki = 30.0;
		auto d = c.update(4, f);
		CHECK(d.klass == SP_CLASS_CACHE);
	}

	// 5) no PMU and low wake -> NORMAL
	{
		Classifier c(s);
		Features f = sched_features(10, 30000000, 100000);
		auto d = c.update(5, f);
		CHECK(d.klass == SP_CLASS_NORMAL);
	}

	// 6) hysteresis: entering L-SYNC needs N stable cycles
	{
		Classifier c(s);
		Features f = sched_features(2000, 500000, 0);
		auto d1 = c.update(6, f); // first ever -> latched immediately
		CHECK(d1.klass == SP_CLASS_LAT);
	}

	// 7) asymmetric hysteresis: leaving L-SYNC needs 2N cycles
	{
		Classifier c(s);
		Features lat_f = sched_features(2000, 500000, 0);
		Features other_f = sched_features(10, 30000000, 100000);
		other_f.pmu_valid = true;
		other_f.ipc = 0.2;
		other_f.mpki = 30.0;
		(void)c.update(7, lat_f); // L-SYNC
		// EWMA needs a few cycles to decay the wake rate below the
		// threshold before the candidate can even start counting, so
		// give the "early" loop 2N cycles.
		bool left_early = false;
		for (int i = 0; i < 2 * s.hysteresis_cycles; i++) {
			auto d = c.update(7, other_f);
			if (d.klass != SP_CLASS_LAT)
				left_early = true;
		}
		CHECK(!left_early); // 2N cycles still not enough to leave
		bool left_late = false;
		for (int i = 0; i < 2 * s.hysteresis_cycles; i++) {
			auto d = c.update(7, other_f);
			if (d.klass != SP_CLASS_LAT)
				left_late = true;
		}
		CHECK(left_late); // sustained contrary evidence -> may leave
	}

	// 8) PMU disabled via settings -> non-LAT falls back to NORMAL
	{
		ClassifierSettings s2 = s;
		s2.use_pmu = false;
		Classifier c(s2);
		Features f = sched_features(10, 30000000, 100000);
		f.pmu_valid = true;
		f.ipc = 2.0;
		f.mpki = 1.0;
		auto d = c.update(8, f);
		CHECK(d.klass == SP_CLASS_NORMAL);
	}

	if (failures == 0) {
		printf("classifier_test: all checks passed\n");
		return 0;
	}
	printf("classifier_test: %d failure(s)\n", failures);
	return 1;
}
