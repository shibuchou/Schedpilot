# SchedPilot experiment summary

- results: `results/mysql-3`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 10 | 479.340 [169.180] | +0.0% | - | - | 55.820 [1.020] | +0.0% | - | - |
| B | 10 | 654.260 [3.650] | +36.5% | - | - | 15.000 [0.000] | -73.1% | [-86.3%, -57.1%] | 0.0001 |
| C | 10 | 885.205 [17.050] | +84.7% | - | - | 12.300 [0.000] | -78.0% | [-91.5%, -62.2%] | 0.0001 |
| D | 10 | 880.825 [15.180] | +83.8% | - | - | 12.300 [0.000] | -78.0% | [-91.4%, -62.2%] | 0.0001 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +36.5% | -73.1% |
| classification effect | C vs B | +35.3% | -18.0% |
| adaptive policy effect | D vs C | -0.5% | +0.0% |
| total effect | D vs A | +83.8% | -78.0% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 10 | +36.92% | [+19.98%, +53.86%] | 10 | 0 |
| B | p99 | 10 | -69.32% | [-78.54%, -60.10%] | 0 | 10 |
| C | qps | 10 | +86.16% | [+63.93%, +108.40%] | 10 | 0 |
| C | p99 | 10 | -74.92% | [-82.50%, -67.34%] | 0 | 10 |
| D | qps | 10 | +85.16% | [+62.04%, +108.27%] | 10 | 0 |
| D | p99 | 10 | -74.84% | [-82.40%, -67.29%] | 0 | 10 |
