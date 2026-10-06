# SchedPilot experiment summary

- results: `results/redis-sanity`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 3 | 17513.330 [540.870] | +0.0% | 17509.102 | +0.0% | 4.455 [0.016] | +0.0% | - | - |
| D | 3 | 48754.640 [2008.420] | +178.4% | 48754.282 | +178.5% | 2.879 [0.008] | -35.4% | [-36.0%, -34.9%] | 0.0463 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +178.4% | -35.4% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 3 | +179.38% | [+154.56%, +204.20%] | 3 | 0 |
| D | goodput@SLO | 3 | +179.58% | [+154.70%, +204.45%] | 3 | 0 |
| D | p99 | 3 | -35.44% | [-35.96%, -34.91%] | 0 | 3 |
