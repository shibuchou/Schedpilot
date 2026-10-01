# SchedPilot experiment summary

- results: `results/pilot-3`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 5 | 75693.920 [3328.830] | +0.0% | 0.759 [0.024] | +0.0% | - | - |
| B | 5 | 77943.620 [8621.860] | +3.0% | 0.647 [0.048] | -14.8% | [-20.3%, -3.1%] | 0.0208 |
| C | 5 | 78274.450 [8775.590] | +3.4% | 0.655 [0.104] | -13.7% | [-19.6%, +4.7%] | 0.2492 |
| D | 5 | 76967.370 [6723.090] | +1.7% | 0.695 [0.064] | -8.4% | [-19.2%, +13.7%] | 0.2492 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +3.0% | -14.8% |
| classification effect | C vs B | +0.4% | +1.2% |
| adaptive policy effect | D vs C | -1.7% | +6.1% |
| total effect | D vs A | +1.7% | -8.4% |
