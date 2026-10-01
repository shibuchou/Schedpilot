# SchedPilot experiment summary

- results: `results/nginx-2`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 18814.450 [4235.680] | +0.0% | - | - | 11.195 [1.830] | +0.0% | - | - |
| B | 20 | 27048.770 [489.930] | +43.8% | - | - | 6.980 [0.130] | -37.7% | [-50.7%, -30.4%] | 0.0000 |
| C | 20 | 38481.250 [3527.650] | +104.5% | - | - | 158.665 [74.180] | +1317.3% | [+877.7%, +1459.1%] | 0.0000 |
| D | 20 | 26971.180 [3063.470] | +43.4% | - | - | 73.635 [168.910] | +557.7% | [+482.3%, +1308.1%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +43.8% | -37.7% |
| classification effect | C vs B | +42.3% | +2173.1% |
| adaptive policy effect | D vs C | -29.9% | -53.6% |
| total effect | D vs A | +43.4% | +557.7% |
