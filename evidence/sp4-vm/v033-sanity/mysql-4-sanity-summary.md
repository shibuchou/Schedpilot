# SchedPilot experiment summary

- results: `results/mysql-4-sanity`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 5 | 561.290 [128.330] | +0.0% | - | - | 56.840 [2.050] | +0.0% | - | - |
| D | 5 | 873.430 [11.980] | +55.6% | - | - | 12.520 [0.220] | -78.0% | [-81.1%, -75.3%] | 0.0078 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +55.6% | -78.0% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 5 | +73.88% | [+39.78%, +107.99%] | 5 | 0 |
| D | p99 | 5 | -78.20% | [-79.07%, -77.32%] | 0 | 5 |
