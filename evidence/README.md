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

## 冻结归档（2026-10-02）

- 冻结矩阵 `formal-4` / `mysql-3` / `nginx-4`（commit `be962b8`）与回归证据 `formal-3`、佐证 `nginx-3`
  的关键摘要归档在 `sp4-vm/<experiment>/`（`summary.md/summary.csv/per_run.csv/experiment.meta.json/env_check.*`）。
- 完整原始数据以 `*.tar.gz` 归档（sha256 见 `submission/evidence_index.md`），存放于实验机归档目录
  与本机归档目录（路径随部署环境）；仓库不随附大文件，只记录哈希与位置。
- `sp4-vm/` 下每个实验目录同时保留当时的函数级证据元数据（内核/commit/二进制 SHA256/场景），归档只追加。
