# SchedPilot experiment summary

- results: `results/formal-5`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 17349.400 [456.770] | +0.0% | 17313.889 | +0.0% | 4.439 [0.056] | +0.0% | - | - |
| D | 20 | 49243.860 [2619.130] | +183.8% | 49240.705 | +184.4% | 2.899 [0.040] | -34.7% | [-35.5%, -34.1%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +183.8% | -34.7% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 20 | +181.49% | [+174.15%, +188.83%] | 20 | 0 |
| D | goodput@SLO | 20 | +182.09% | [+174.74%, +189.43%] | 20 | 0 |
| D | p99 | 20 | -34.80% | [-35.41%, -34.19%] | 0 | 20 |
