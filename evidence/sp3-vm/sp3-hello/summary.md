# SchedPilot experiment summary

- results: `results/sp3-hello`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 2 | 18811.380 [47.940] | +0.0% | 18721.407 | +0.0% | 4.507 [0.088] | +0.0% | - | - |
| D | 2 | 43073.245 [510.130] | +129.0% | 43073.245 | +130.1% | 3.127 [0.048] | -30.6% | [-44.7%, -16.5%] | - |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| total effect | D vs A | +129.0% | -30.6% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| D | qps | 2 | +128.98% | [+108.04%, +149.91%] | 2 | 0 |
| D | goodput@SLO | 2 | +130.08% | [+100.59%, +159.58%] | 2 | 0 |
| D | p99 | 2 | -30.62% | [-32.46%, -28.78%] | 0 | 2 |
