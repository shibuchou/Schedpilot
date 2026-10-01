# SchedPilot experiment summary

- results: `results/mysql-2`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 526.610 [133.490] | +0.0% | - | - | 55.820 [2.010] | +0.0% | - | - |
| B | 20 | 636.705 [7.300] | +20.9% | - | - | 15.270 [0.000] | -72.6% | [-83.6%, -52.9%] | 0.0000 |
| C | 20 | 851.390 [8.100] | +61.7% | - | - | 12.865 [0.230] | -77.0% | [-88.5%, -57.8%] | 0.0000 |
| D | 20 | 855.200 [9.430] | +62.4% | - | - | 12.750 [0.230] | -77.2% | [-88.6%, -57.9%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +20.9% | -72.6% |
| classification effect | C vs B | +33.7% | -15.7% |
| adaptive policy effect | D vs C | +0.4% | -0.9% |
| total effect | D vs A | +62.4% | -77.2% |
