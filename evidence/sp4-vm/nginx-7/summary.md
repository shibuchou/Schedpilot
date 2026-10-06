# SchedPilot experiment summary

- results: `results/nginx-7`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 18677.610 [6572.920] | +0.0% | - | - | 11.055 [4.930] | +0.0% | - | - |
| B | 20 | 26683.915 [659.790] | +42.9% | - | - | 7.040 [0.150] | -36.3% | [-52.6%, -35.2%] | 0.0000 |
| C | 20 | 44292.965 [1435.670] | +137.1% | - | - | 3.715 [0.160] | -66.4% | [-79.1%, -61.7%] | 0.0000 |
| D | 20 | 44473.765 [1021.640] | +138.1% | - | - | 3.685 [0.280] | -66.7% | [-79.2%, -61.8%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +42.9% | -36.3% |
| classification effect | C vs B | +66.0% | -47.2% |
| adaptive policy effect | D vs C | +0.4% | -0.8% |
| total effect | D vs A | +138.1% | -66.7% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +61.14% | [+44.61%, +77.67%] | 20 | 0 |
| B | p99 | 20 | -42.22% | [-46.61%, -37.82%] | 0 | 20 |
| C | qps | 20 | +167.81% | [+141.06%, +194.56%] | 20 | 0 |
| C | p99 | 20 | -69.61% | [-71.84%, -67.37%] | 0 | 20 |
| D | qps | 20 | +169.82% | [+142.58%, +197.06%] | 20 | 0 |
| D | p99 | 20 | -69.63% | [-72.09%, -67.16%] | 0 | 20 |
