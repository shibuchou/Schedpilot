# SchedPilot experiment summary

- results: `results/pilot-5`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 5 | 17763.130 [724.910] | +0.0% | 4.471 [0.000] | +0.0% | - | - |
| B | 5 | 29264.700 [316.840] | +64.7% | 4.711 [0.128] | +5.4% | [+1.8%, +6.8%] | 0.0082 |
| C | 5 | 35734.390 [1382.410] | +101.2% | 4.535 [0.040] | +1.4% | [+0.4%, +3.3%] | 0.0082 |
| D | 5 | 36692.170 [772.600] | +106.6% | 4.567 [0.168] | +2.1% | [-2.5%, +3.9%] | 0.5959 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +64.7% | +5.4% |
| classification effect | C vs B | +22.1% | -3.7% |
| adaptive policy effect | D vs C | +2.7% | +0.7% |
| total effect | D vs A | +106.6% | +2.1% |
