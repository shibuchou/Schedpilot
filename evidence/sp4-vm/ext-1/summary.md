# SchedPilot experiment summary

- results: `results/ext-1`
- baseline arm: **A** (openEuler default fair-class scheduler; competition text: default CFS)
- delta is (arm - baseline) / baseline; negative latency delta = better

| arm | n | QPS median [IQR] | QPS delta | goodput@SLO median | goodput delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |
|---|---|---|---|---|---|---|---|---|---|
| A | 10 | 17302.805 [744.830] | +0.0% | 17296.477 | +0.0% | 4.447 [0.040] | +0.0% | - | - |
| B | 10 | 29039.930 [1044.690] | +67.8% | 28819.586 | +66.6% | 4.719 [0.152] | +6.1% | [+4.5%, +7.6%] | 0.0002 |
| D | 10 | 37882.065 [1113.660] | +118.9% | 37737.361 | +118.2% | 4.507 [0.056] | +1.3% | [+1.0%, +2.8%] | 0.0002 |
| X-flatcg | 10 | 17622.160 [871.100] | +1.8% | 17601.172 | +1.8% | 4.447 [0.048] | +0.0% | [-1.0%, +1.1%] | 0.7311 |
| X-simple | 10 | 8708.200 [189.340] | -49.7% | 4752.241 | -72.5% | 20.039 [0.192] | +350.6% | [+350.9%, +354.8%] | 0.0002 |

## Attribution chain

| step | comparison | QPS delta (median) | p99 delta (median) |
|---|---|---|---|
| sched_ext effect | B vs A | +67.8% | +6.1% |
| total effect | D vs A | +118.9% | +1.3% |
