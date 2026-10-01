# SchedPilot experiment summary

- results: `results/noif-1`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|
| A | 10 | 84241.740 [999.020] | +0.0% | 0.759 [0.016] | +0.0% | - | - |
| B | 10 | 81630.315 [1969.390] | -3.1% | 0.615 [0.016] | -19.0% | [-21.6%, -16.3%] | 0.0001 |
| C | 10 | 82896.840 [1186.620] | -1.6% | 0.659 [0.040] | -13.2% | [-16.3%, -9.4%] | 0.0001 |
| D | 10 | 82719.040 [1416.720] | -1.8% | 0.659 [0.032] | -13.2% | [-15.6%, -9.9%] | 0.0001 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | -3.1% | -19.0% |
| classification effect | C vs B | +1.6% | +7.2% |
| adaptive policy effect | D vs C | -0.2% | +0.0% |
| total effect | D vs A | -1.8% | -13.2% |
