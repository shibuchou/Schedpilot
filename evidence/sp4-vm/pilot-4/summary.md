# SchedPilot experiment summary

- results: `results/pilot-4`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 6 | 74564.845 [1222.570] | +0.0% | 0.739 [0.056] | +0.0% | - | - |
| B | 6 | 73333.575 [7818.210] | -1.7% | 0.683 [0.056] | -7.6% | [-14.0%, -0.5%] | 0.0431 |
| C | 6 | 67651.590 [4758.130] | -9.3% | 0.795 [0.032] | +7.6% | [+0.3%, +17.7%] | 0.0127 |
| D | 6 | 76380.890 [13607.230] | +2.4% | 0.707 [0.104] | -4.3% | [-15.4%, +2.8%] | 0.1262 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | -1.7% | -7.6% |
| classification effect | C vs B | -7.7% | +16.4% |
| adaptive policy effect | D vs C | +12.9% | -11.1% |
| total effect | D vs A | +2.4% | -4.3% |
