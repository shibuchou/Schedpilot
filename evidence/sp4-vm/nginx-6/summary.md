# SchedPilot experiment summary

- results: `results/nginx-6`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 19339.580 [3365.280] | +0.0% | - | - | 11.070 [1.440] | +0.0% | - | - |
| B | 20 | 26561.970 [869.790] | +37.3% | - | - | 7.115 [0.230] | -35.7% | [-46.7%, -28.2%] | 0.0000 |
| C | 20 | 44556.350 [1173.050] | +130.4% | - | - | 3.625 [0.220] | -67.3% | [-77.1%, -58.5%] | 0.0000 |
| D | 20 | 36435.025 [1320.140] | +88.4% | - | - | 4.990 [0.350] | -54.9% | [-65.4%, -46.8%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +37.3% | -35.7% |
| classification effect | C vs B | +67.7% | -49.1% |
| adaptive policy effect | D vs C | -18.2% | +37.7% |
| total effect | D vs A | +88.4% | -54.9% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +45.20% | [+30.91%, +59.50%] | 19 | 1 |
| B | p99 | 20 | -34.68% | [-42.14%, -27.23%] | 2 | 18 |
| C | qps | 20 | +143.11% | [+118.66%, +167.56%] | 20 | 0 |
| C | p99 | 20 | -66.25% | [-70.54%, -61.96%] | 0 | 20 |
| D | qps | 20 | +99.40% | [+78.20%, +120.61%] | 20 | 0 |
| D | p99 | 20 | -53.97% | [-59.74%, -48.21%] | 0 | 20 |
