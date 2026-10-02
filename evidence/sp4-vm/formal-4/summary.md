# SchedPilot experiment summary

- results: `results/formal-4`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 17274.320 [494.450] | +0.0% | 17235.079 | +0.0% | 4.451 [0.040] | +0.0% | - | - |
| B | 20 | 28794.560 [998.350] | +66.7% | 28638.257 | +66.2% | 4.703 [0.112] | +5.7% | [+4.8%, +6.7%] | 0.0000 |
| C | 20 | 45948.700 [2392.120] | +166.0% | 45945.908 | +166.6% | 2.931 [0.040] | -34.1% | [-34.8%, -33.6%] | 0.0000 |
| D | 20 | 47077.040 [1345.100] | +172.5% | 47076.699 | +173.1% | 2.895 [0.040] | -35.0% | [-35.2%, -34.1%] | 0.0000 |
| d-no-bg | 20 | 46918.505 [1934.050] | +171.6% | 46915.740 | +172.2% | 2.919 [0.056] | -34.4% | [-35.2%, -34.1%] | 0.0000 |
| d-no-llc | 20 | 46258.345 [2991.690] | +167.8% | 46256.943 | +168.4% | 2.911 [0.064] | -34.6% | [-35.2%, -33.9%] | 0.0000 |
| d-no-pmu | 20 | 46453.900 [1936.650] | +168.9% | 46453.201 | +169.5% | 2.903 [0.048] | -34.8% | [-35.2%, -34.0%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +66.7% | +5.7% |
| classification effect | C vs B | +59.6% | -37.7% |
| adaptive policy effect | D vs C | +2.5% | -1.2% |
| total effect | D vs A | +172.5% | -35.0% |
| ablation: no PMU | d-no-pmu vs D | -1.3% | +0.3% |
| ablation: no LLC control | d-no-llc vs D | -1.7% | +0.6% |
| ablation: no BG contain | d-no-bg vs D | -0.3% | +0.8% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +66.34% | [+63.56%, +69.11%] | 20 | 0 |
| B | goodput@SLO | 20 | +65.61% | [+62.76%, +68.45%] | 20 | 0 |
| B | p99 | 20 | +5.80% | [+4.85%, +6.75%] | 20 | 0 |
| C | qps | 20 | +167.39% | [+162.31%, +172.48%] | 20 | 0 |
| C | goodput@SLO | 20 | +167.75% | [+162.64%, +172.86%] | 20 | 0 |
| C | p99 | 20 | -34.16% | [-34.74%, -33.59%] | 0 | 20 |
| D | qps | 20 | +169.81% | [+164.42%, +175.20%] | 20 | 0 |
| D | goodput@SLO | 20 | +170.17% | [+164.79%, +175.55%] | 20 | 0 |
| D | p99 | 20 | -34.67% | [-35.10%, -34.24%] | 0 | 20 |
| d-no-bg | qps | 20 | +171.94% | [+167.04%, +176.85%] | 20 | 0 |
| d-no-bg | goodput@SLO | 20 | +172.30% | [+167.39%, +177.21%] | 20 | 0 |
| d-no-bg | p99 | 20 | -34.66% | [-35.21%, -34.11%] | 0 | 20 |
| d-no-llc | qps | 20 | +167.97% | [+162.15%, +173.80%] | 20 | 0 |
| d-no-llc | goodput@SLO | 20 | +168.33% | [+162.50%, +174.16%] | 20 | 0 |
| d-no-llc | p99 | 20 | -34.55% | [-35.10%, -34.00%] | 0 | 20 |
| d-no-pmu | qps | 20 | +169.12% | [+163.36%, +174.88%] | 20 | 0 |
| d-no-pmu | goodput@SLO | 20 | +169.47% | [+163.75%, +175.20%] | 20 | 0 |
| d-no-pmu | p99 | 20 | -34.58% | [-35.05%, -34.11%] | 0 | 20 |
