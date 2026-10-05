# SchedPilot experiment summary

- results: `results/smoke-cleanup`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 3 | 16950.820 [742.760] | +0.0% | 16946.779 | +0.0% | 4.431 [0.032] | +0.0% | - | - |
| D | 3 | 49168.070 [532.980] | +190.1% | 49162.134 | +190.1% | 2.911 [0.056] | -34.3% | [-36.6%, -32.7%] | 0.0495 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +190.1% | -34.3% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 3 | +187.96% | [+174.35%, +201.58%] | 3 | 0 |
| D | goodput@SLO | 3 | +188.25% | [+174.35%, +202.15%] | 3 | 0 |
| D | p99 | 3 | -34.68% | [-36.24%, -33.13%] | 0 | 3 |
