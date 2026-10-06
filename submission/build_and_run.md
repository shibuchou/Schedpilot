# 构建与运行（提交包）

完整部署与回滚说明见 `docs/03_deploy_rollback.md`；这里是提交复现的最短路径。

## 目标环境

- openEuler 24.03 LTS SP4 + 启用 `CONFIG_SCHED_CLASS_EXT` 的内核（发行版或自编译，本仓库在
  `6.6.0-schedpilot` 自编译内核上完成全部正式实验）
- clang ≥ 17、libbpf、bpftool、g++、python3；root 权限
- 内核源码树（`/usr/src/linux-*`）用于权威构建

## 构建

```bash
scripts/env_check.sh                       # 先确认 sched_ext / BTF / PMU
KSRC=/usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64
scripts/build.sh --kernel-src "$KSRC"      # loader + BPF + daemon
scripts/build_external.sh                  # 可选：scx_simple / scx_flatcg 对照
```

## 运行

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
scripts/schedpilotctl.sh status
scripts/schedpilotctl.sh stop        # 或 rollback
```

## 基准负载环境准备

```bash
# Redis：使用仓库内 bench/redis-schedpilot.conf，实验编排器会自动启动
# Nginx：dnf install nginx wrk（配置见 bench/nginx-schedpilot.conf，自动启动）
# MySQL：一条命令完成安装/初始化/授权/sysbench 数据准备
scripts/setup_mysql.sh
```

`scripts/setup_mysql.sh` 会把 `bench/mysql-schedpilot.cnf` 安装到 `/etc/schedpilot-mysql.cnf`
（可用环境变量 `MYSQL_CNF` 覆盖），端口 3307，数据目录 `/var/lib/schedpilot-mysql`。

## 复现正式实验

冻结矩阵 commit：`be962b8a4f093e4c23396d7ce78afc57b866b234`（`git checkout be962b8` 后按 `scripts/build.sh` 构建；
预期结果与二进制 SHA256 见 `docs/04_test_report.md` §6.10 与 `submission/evidence_index.md`）。

```bash
# Redis 主矩阵（冻结版；自动记录 git commit / 内核 / 二进制 SHA256，
# 逐臂校验调度器状态，默认 fail-fast 且污染轮次判定无效）
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-4
python3 bench/analyze_results.py --results results/formal-4 --baseline A

# Nginx：推荐部署入口 + 回归测试（分类模式为实测最优，basic 可回退）
scripts/deploy_nginx.sh                 # 默认 adaptive；--mode basic 回退
tests/test_nginx_basic.sh
bench/abcd_experiment.sh --workload nginx --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D --results results/nginx-7

# MySQL（先跑 scripts/setup_mysql.sh 准备环境）
bench/abcd_experiment.sh --workload mysql --runs 10 --duration 60 --warmup 10 \
  --arms A,B,C,D --results results/mysql-3
```

分析输出含逐轮配对复算（mean Δ%、95% CI、更高/更低轮数）；`summary.md` 的配对表是
最终统计口径（`p` 值列仅对 p99 的 Mann-Whitney，不用于吞吐结论）。

## 测试

```bash
make check                          # shell/python 检查 + 分类器单元测试
tests/test_fault_injection.sh       # 故障注入（需独占调度器）
tests/test_soak.sh --duration 1800  # 30 分钟长稳
scripts/demo.sh                     # 一键演示（A vs D 快速曲线）
```
