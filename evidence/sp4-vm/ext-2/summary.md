# SchedPilot experiment summary

- results: `results/ext-2`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 10 | 17438.850 [391.510] | +0.0% | 17426.118 | +0.0% | 4.451 [0.064] | +0.0% | - | - |
| B | 10 | 28781.215 [1123.280] | +65.0% | 28670.035 | +64.5% | 4.695 [0.088] | +5.5% | [+4.7%, +6.7%] | 0.0002 |
| D | 10 | 48080.360 [5021.940] | +175.7% | 48080.271 | +175.9% | 2.895 [0.072] | -35.0% | [-35.8%, -33.9%] | 0.0002 |
| X-simple | 10 | 8421.560 [99.090] | -51.7% | 4535.870 | -74.0% | 20.087 [0.128] | +351.3% | [+350.5%, +353.2%] | 0.0002 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +65.0% | +5.5% |
| total effect | D vs A | +175.7% | -35.0% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 10 | +64.72% | [+60.81%, +68.63%] | 10 | 0 |
| B | goodput@SLO | 10 | +63.99% | [+59.97%, +68.00%] | 10 | 0 |
| B | p99 | 10 | +5.67% | [+4.68%, +6.66%] | 10 | 0 |
| D | qps | 10 | +169.62% | [+158.19%, +181.06%] | 10 | 0 |
| D | goodput@SLO | 10 | +169.84% | [+158.49%, +181.19%] | 10 | 0 |
| D | p99 | 10 | -34.86% | [-35.68%, -34.05%] | 0 | 10 |
| X-simple | qps | 10 | -51.28% | [-52.52%, -50.04%] | 0 | 10 |
| X-simple | goodput@SLO | 10 | -73.63% | [-74.53%, -72.73%] | 0 | 10 |
| X-simple | p99 | 10 | +351.86% | [+349.02%, +354.71%] | 10 | 0 |
