# SchedPilot experiment summary

- results: `results/formal-2`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 20 | 17999.105 [519.380] | +0.0% | 4.431 [0.032] | +0.0% | - | - |
| B | 20 | 30416.450 [1114.170] | +69.0% | 4.651 [0.128] | +5.0% | [+4.1%, +5.8%] | 0.0000 |
| C | 20 | 37956.895 [1550.010] | +110.9% | 4.555 [0.064] | +2.8% | [+2.2%, +3.2%] | 0.0000 |
| D | 20 | 39048.150 [1256.600] | +116.9% | 4.503 [0.048] | +1.6% | [+1.0%, +2.2%] | 0.0000 |
| d-no-bg | 20 | 39180.980 [1809.550] | +117.7% | 4.491 [0.080] | +1.4% | [+0.7%, +2.0%] | 0.0004 |
| d-no-llc | 20 | 37725.845 [2463.820] | +109.6% | 4.519 [0.104] | +2.0% | [+1.3%, +2.9%] | 0.0001 |
| d-no-pmu | 20 | 38521.865 [2566.440] | +114.0% | 4.503 [0.056] | +1.6% | [+0.9%, +2.3%] | 0.0003 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +69.0% | +5.0% |
| classification effect | C vs B | +24.8% | -2.1% |
| adaptive policy effect | D vs C | +2.9% | -1.1% |
| total effect | D vs A | +116.9% | +1.6% |
| ablation: no PMU | d-no-pmu vs D | -1.3% | +0.0% |
| ablation: no LLC control | d-no-llc vs D | -3.4% | +0.4% |
| ablation: no BG contain | d-no-bg vs D | +0.3% | -0.3% |
