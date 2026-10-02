# SchedPilot experiment summary

- results: `results/nginx-4`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 18726.030 [4696.330] | +0.0% | - | - | 11.095 [2.010] | +0.0% | - | - |
| B | 20 | 26659.185 [680.670] | +42.4% | - | - | 7.005 [0.210] | -36.9% | [-49.6%, -27.2%] | 0.0001 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +42.4% | -36.9% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +50.14% | [+35.13%, +65.15%] | 20 | 0 |
| B | p99 | 20 | -34.05% | [-43.50%, -24.60%] | 3 | 17 |
