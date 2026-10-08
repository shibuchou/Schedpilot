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
| 容器/cgroup 目标回归测试 | `tests/test_cgroup_targeting.sh` |
| 动态 BG CPU pool 回归测试 | `tests/test_bg_cpu_pool.sh` |
| 调度器开销测量 | `bench/measure_overhead.sh` |
| 单元测试 | `tests/classifier_test.cpp`（`make test`） |
| 部署与回滚说明 | `docs/03_deploy_rollback.md` |
| 测试方案 | `docs/02_test_plan.md` |
| MVP 范围 | `docs/00_mvp_scope.md` |
| 测试报告（含正式矩阵与负结果） | `docs/04_test_report.md` |
| 10 分钟演示流程（评审现场版，实机校准） | `docs/05_demo_runbook.md` |
| 演示前风险清单与答辩 Q&A | `docs/06_demo_risks_qa.md` |
| 答辩材料包（PPT 提纲 + 视频脚本 + Q&A） | `submission/defense_pack.md` |
| **项目说明书（docx / pdf）** | `submission/SchedPilot_项目说明书.docx`、`.pdf` |
| **说明书配图（7 张，PNG + Graphviz `.dot` 源码）** | `docs/assets/diagrams/` |
| **最终构建正式矩阵证据（formal-5，HEAD 65c4485）** | `evidence/sp4-vm/formal-5/` |
| 设计方案（含长期 roadmap） | `SchedPilot_设计方案.md` |
| 证据索引 | `submission/evidence_index.md` |
| 一键演示 | `scripts/demo.sh` |
| Nginx 部署入口（adaptive 推荐 / basic 回退） | `scripts/deploy_nginx.sh` |

## 复现入口

```bash
scripts/env_check.sh --json evidence/sp4-vm/env_check.json
# SP4（注意：--install 只装 /usr/local/bin，不更新 build/；见 docs/06 S1 的提醒）
scripts/build.sh --kernel-src /usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64 --install
# SP3 用的是另一棵源码树（内核自建，见 docs/04 §6.12）：
#   scripts/build.sh --kernel-src /usr/src/kernel-source-6.6.0-<ver>.oe2403sp3
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-4

# 最终构建（HEAD 65c4485）的正式矩阵：A/D 两臂 × 20 轮
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,D --results results/formal-5
```

> **冻结主键建议以二进制 SHA256 为准，而非 commit**：归档中同一个 `be962b8` 出现过两个不同的
> loader 哈希（`9d1e904f` 与 `76f0cad3`），说明至少有一次跑的是改过源码但未提交的工作树。
> `formal-5` 起按"commit + 二进制 SHA256"双主键记录。

Baseline 口径：openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）。
