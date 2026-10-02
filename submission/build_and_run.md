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

```bash
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-2
python3 bench/analyze_results.py --results results/formal-2 --baseline A
# Nginx / MySQL:
bench/abcd_experiment.sh --workload nginx --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D --results results/nginx-1
bench/abcd_experiment.sh --workload mysql --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D --results results/mysql-1
```

## 测试

```bash
make check                          # shell/python 检查 + 分类器单元测试
tests/test_fault_injection.sh       # 故障注入（需独占调度器）
tests/test_soak.sh --duration 1800  # 30 分钟长稳
scripts/demo.sh                     # 一键演示（A vs D 快速曲线）
```
