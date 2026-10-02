# SchedPilot experiment summary

- results: `results/nginx-3`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 19501.510 [4943.540] | +0.0% | - | - | 11.010 [1.730] | +0.0% | - | - |
| B | 20 | 28282.915 [866.160] | +45.0% | - | - | 6.875 [0.210] | -37.6% | [-49.8%, -30.3%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +45.0% | -37.6% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +52.43% | [+37.34%, +67.52%] | 20 | 0 |
| B | p99 | 20 | -36.89% | [-45.01%, -28.76%] | 2 | 18 |
