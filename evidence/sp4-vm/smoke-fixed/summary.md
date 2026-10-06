# SchedPilot experiment summary

- results: `results/smoke-fixed`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 3 | 17556.140 [793.970] | +0.0% | 17539.230 | +0.0% | 4.407 [0.024] | +0.0% | - | - |
| D | 3 | 52846.730 [7650.710] | +201.0% | 52846.730 | +201.3% | 2.815 [0.080] | -36.1% | [-38.4%, -33.6%] | 0.0463 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +201.0% | -36.1% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 3 | +203.52% | [+131.70%, +275.35%] | 3 | 0 |
| D | goodput@SLO | 3 | +203.72% | [+131.50%, +275.94%] | 3 | 0 |
| D | p99 | 3 | -36.00% | [-37.84%, -34.16%] | 0 | 3 |
