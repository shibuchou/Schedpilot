# SchedPilot experiment summary

- results: `results/formal-1`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 20 | 82398.610 [1252.110] | +0.0% | 0.631 [0.016] | +0.0% | - | - |
| B | 20 | 80499.335 [1814.190] | -2.3% | 0.607 [0.016] | -3.8% | [-8.6%, -3.1%] | 0.0000 |
| C | 20 | 81204.085 [1768.630] | -1.4% | 0.655 [0.024] | +3.8% | [-0.6%, +5.2%] | 0.0050 |
| D | 20 | 80498.220 [2212.780] | -2.3% | 0.647 [0.032] | +2.5% | [-1.5%, +4.2%] | 0.0189 |
| d-no-bg | 20 | 81037.680 [2172.880] | -1.7% | 0.651 [0.032] | +3.2% | [-1.3%, +5.8%] | 0.0245 |
| d-no-llc | 20 | 81296.870 [1184.030] | -1.3% | 0.651 [0.024] | +3.2% | [-2.0%, +3.7%] | 0.0380 |
| d-no-pmu | 20 | 81275.300 [777.470] | -1.4% | 0.659 [0.016] | +4.4% | [-0.7%, +4.8%] | 0.0026 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | -2.3% | -3.8% |
| classification effect | C vs B | +0.9% | +7.9% |
| adaptive policy effect | D vs C | -0.9% | -1.2% |
| total effect | D vs A | -2.3% | +2.5% |
| ablation: no PMU | d-no-pmu vs D | +1.0% | +1.9% |
| ablation: no LLC control | d-no-llc vs D | +1.0% | +0.6% |
| ablation: no BG contain | d-no-bg vs D | +0.7% | +0.6% |
