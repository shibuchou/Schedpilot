# SchedPilot 提交包

本目录是省赛提交材料的索引入口；源码、脚本与全部证据位于仓库对应目录。

## 交付物清单

| 交付物 | 位置 |
|---|---|
| 调度器源码（BPF 数据面 + loader） | `bpf/`、`loader/` |
| 用户态控制守护进程 | `daemon/` |
| 构建脚本（开发机 / 目标内核树） | `scripts/build.sh`、`Makefile` |
| 一键控制（启动/停止/状态/回退） | `scripts/schedpilotctl.sh` |
| 环境能力探测 | `scripts/env_check.sh` |
| 三负载基准（Redis/Nginx/MySQL） | `bench/run_redis.sh`、`bench/run_nginx.sh`、`bench/run_mysql.sh` |
| A/B/C/D + 消融自动实验 | `bench/abcd_experiment.sh` |
| 统计与归因 | `bench/analyze_results.py`（含固定 SLO goodput） |
| 故障注入测试 | `tests/test_fault_injection.sh` |
| 长稳测试（soak） | `tests/test_soak.sh` |
| 单元测试 | `tests/classifier_test.cpp`（`make test`） |
| 部署与回滚说明 | `docs/03_deploy_rollback.md` |
| 测试方案 | `docs/02_test_plan.md` |
| MVP 范围 | `docs/00_mvp_scope.md` |
| 测试报告（含正式矩阵与负结果） | `docs/04_test_report.md` |
| 设计方案（含长期 roadmap） | `SchedPilot_设计方案.md` |
| 证据索引 | `submission/evidence_index.md` |
| 一键演示 | `scripts/demo.sh` |

## 复现入口

```bash
scripts/env_check.sh --json evidence/sp4-vm/env_check.json
scripts/build.sh --kernel-src /usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64 --install
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-2
```

Baseline 口径：openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）。
