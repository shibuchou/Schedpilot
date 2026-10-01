# Evidence archive conventions

本目录保存实验与验证的**原始证据**，禁止手工修改已归档文件（新增文件只追加）。

- `rd350x-dev-20260929/`：开发机（Ubuntu 24.04 / kernel 6.8）编译验证证据。
  - `env_check.json`：`scripts/env_check.sh` 的真实输出。
  - `compile_evidence.txt`：编译器/库版本与构建产物 SHA256。
- 目标环境实验完成后新增 `sp4-<YYYYMMDD>/`：
  - `env_check.json`
  - `results/<host>-<ts>/`（由 `bench/abcd_experiment.sh` 生成）：
    - `experiment.meta.json`、`per_run.csv`、`summary.csv`、`summary.md`
    - `<arm>/run-NN/`：`redis.out`、`redis_summary.json`、`perf_stat.txt`、
      `sched_stats_{before,after}.txt`、`cfg_{before,after}.json`、
      `sched_status_{before,after}.txt`、`logs/schedpilotd-*.jsonl`、
      `proc_stat_{before,after}.txt`、`dmesg_{before,after}.txt`
    - `env_check.json`

约定：报告中的每个数字都必须能回溯到某个 run 目录中的原始文件；缺失数据一律标注“未执行”，不做推算填充。
