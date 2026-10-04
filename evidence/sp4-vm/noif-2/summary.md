# SchedPilot experiment summary

- results: `results/noif-2`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 10 | 84783.250 [868.000] | +0.0% | 84783.240 | +0.0% | 0.751 [0.016] | +0.0% | - | - |
| B | 10 | 80292.780 [2630.460] | -5.3% | 80292.780 | -5.3% | 0.619 [0.016] | -17.6% | [-19.7%, -15.6%] | 0.0001 |
| C | 10 | 81811.895 [979.940] | -3.5% | 81811.895 | -3.5% | 0.659 [0.016] | -12.3% | [-14.3%, -9.8%] | 0.0001 |
| D | 10 | 82021.085 [1002.730] | -3.3% | 82021.085 | -3.3% | 0.663 [0.008] | -11.7% | [-13.8%, -8.4%] | 0.0002 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | -5.3% | -17.6% |
| classification effect | C vs B | +1.9% | +6.5% |
| adaptive policy effect | D vs C | +0.3% | +0.6% |
| total effect | D vs A | -3.3% | -11.7% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 10 | -5.67% | [-7.15%, -4.19%] | 0 | 10 |
| B | goodput@SLO | 10 | -5.67% | [-7.15%, -4.19%] | 0 | 10 |
| B | p99 | 10 | -17.59% | [-18.95%, -16.23%] | 0 | 10 |
| C | qps | 10 | -3.20% | [-4.00%, -2.41%] | 0 | 10 |
| C | goodput@SLO | 10 | -3.20% | [-4.00%, -2.41%] | 0 | 10 |
| C | p99 | 10 | -12.03% | [-13.89%, -10.17%] | 0 | 10 |
| D | qps | 10 | -3.28% | [-4.52%, -2.04%] | 0 | 10 |
| D | goodput@SLO | 10 | -3.28% | [-4.52%, -2.04%] | 0 | 10 |
| D | p99 | 10 | -11.04% | [-13.96%, -8.12%] | 0 | 10 |
