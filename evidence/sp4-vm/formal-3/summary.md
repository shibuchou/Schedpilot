# SchedPilot experiment summary

- results: `results/formal-3`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 20 | 17307.685 [553.820] | +0.0% | 17295.092 | +0.0% | 4.451 [0.024] | +0.0% | - | - |
| B | 20 | 28480.960 [580.990] | +64.6% | 28303.625 | +63.7% | 4.715 [0.088] | +5.9% | [+4.6%, +6.2%] | 0.0000 |
| C | 20 | 25937.525 [2294.230] | +49.9% | 22697.338 | +31.2% | 9.539 [0.192] | +114.3% | [+112.8%, +115.6%] | 0.0000 |
| D | 20 | 20138.330 [1813.120] | +16.4% | 16045.737 | -7.2% | 9.923 [0.144] | +122.9% | [+122.4%, +124.9%] | 0.0000 |
| d-no-bg | 20 | 19760.225 [874.150] | +14.2% | 15662.061 | -9.4% | 9.991 [0.160] | +124.5% | [+123.4%, +126.4%] | 0.0000 |
| d-no-llc | 20 | 19945.780 [1517.070] | +15.2% | 15834.954 | -8.4% | 9.975 [0.160] | +124.1% | [+122.6%, +125.1%] | 0.0000 |
| d-no-pmu | 20 | 19996.550 [2311.150] | +15.5% | 15905.772 | -8.0% | 10.091 [0.560] | +126.7% | [+126.0%, +133.1%] | 0.0000 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +64.6% | +5.9% |
| classification effect | C vs B | -8.9% | +102.3% |
| adaptive policy effect | D vs C | -22.4% | +4.0% |
| total effect | D vs A | +16.4% | +122.9% |
| ablation: no PMU | d-no-pmu vs D | -0.7% | +1.7% |
| ablation: no LLC control | d-no-llc vs D | -1.0% | +0.5% |
| ablation: no BG contain | d-no-bg vs D | -1.9% | +0.7% |

## Paired per-run comparison vs baseline (same run index)

Mean of per-run paired deltas with 95% CI; `higher`/`lower` are the
number of runs where the arm was above/below the baseline for that metric.

| arm | metric | n | mean Δ% | 95% CI | runs higher | runs lower |
|---|---|---|---|---|---|---|
| B | qps | 20 | +64.72% | [+61.57%, +67.87%] | 20 | 0 |
| B | goodput@SLO | 20 | +63.91% | [+60.68%, +67.13%] | 20 | 0 |
| B | p99 | 20 | +5.41% | [+4.64%, +6.19%] | 20 | 0 |
| C | qps | 20 | +48.17% | [+43.67%, +52.66%] | 20 | 0 |
| C | goodput@SLO | 20 | +29.88% | [+25.63%, +34.12%] | 20 | 0 |
| C | p99 | 20 | +114.23% | [+112.96%, +115.51%] | 20 | 0 |
| D | qps | 20 | +15.75% | [+11.65%, +19.85%] | 19 | 1 |
| D | goodput@SLO | 20 | -7.68% | [-11.92%, -3.43%] | 4 | 16 |
| D | p99 | 20 | +123.69% | [+122.36%, +125.01%] | 20 | 0 |
| d-no-bg | qps | 20 | +13.49% | [+10.70%, +16.28%] | 19 | 1 |
| d-no-bg | goodput@SLO | 20 | -10.12% | [-12.93%, -7.32%] | 0 | 20 |
| d-no-bg | p99 | 20 | +124.92% | [+123.27%, +126.57%] | 20 | 0 |
| d-no-llc | qps | 20 | +15.33% | [+11.70%, +18.96%] | 20 | 0 |
| d-no-llc | goodput@SLO | 20 | -8.21% | [-12.02%, -4.39%] | 2 | 18 |
| d-no-llc | p99 | 20 | +123.84% | [+122.62%, +125.05%] | 20 | 0 |
| d-no-pmu | qps | 20 | +12.64% | [+7.13%, +18.15%] | 18 | 2 |
| d-no-pmu | goodput@SLO | 20 | -10.94% | [-16.61%, -5.27%] | 4 | 16 |
| d-no-pmu | p99 | 20 | +129.54% | [+126.26%, +132.81%] | 20 | 0 |
