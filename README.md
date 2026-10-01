# SchedPilot

面向云原生高性能负载的 eBPF/sched_ext 用户态自适应调度系统

- 赛题：华为命题《基于 BPF/sched_ext 的用户态高性能动态调度器》（国产操作系统软件组）
- 状态：**v0.3 省赛 MVP**（最小闭环：Redis + PMU/调度事件感知 + 三分类 + 三类 DSQ + 自适应策略 + A/B/C/D 可归因实验）
- 主环境：**openEuler 24.03 LTS SP4**（冻结）；SP1/SP3 仅作有时间时的兼容验证
- Baseline 口径：**openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）**；不把 Linux 6.6 fair-class 内部实现等同于经典 CFS

## 最小闭环

```
Workload(Redis + 干扰)
   │  eBPF: wakeup / runtime / run delay      userspace: PMU cycles/instructions/LLC
   ▼
schedpilotd  EWMA + hysteresis 三分类: L-SYNC / C-COMPUTE / M-BOUND  (+ 显式 BG)
   │  pinned maps: class_map / cfg(带 generation + heartbeat)
   ▼
scx_schedpilot (SCX_OPS)   LAT DSQ / COMP DSQ / CACHE DSQ (+ LLC 软亲和 / 迁移惩罚 / 预抢占)
```

## 仓库结构

```
bpf/        scx_schedpilot.bpf.c, intf.h            # sched_ext 数据面
loader/     scx_schedpilot.c                        # 调度器 loader（scx_schedpilot）
daemon/     schedpilotd + pmu_sampler/classifier/bpf_iface
configs/    schedpilot.conf, redis.conf             # 目标/分类/BG/消融配置
scripts/    env_check.sh build.sh schedpilotctl.sh sync_to_host.sh
bench/      run_redis.sh abcd_experiment.sh interference.sh analyze_results.py
docs/       MVP 范围 / 测试方案 / 部署回滚 / 测试报告
third_party/scx-dev/                                 # 开发用 sched_ext 头文件（目标构建使用内核树）
```

## 快速开始（开发机）

```bash
make                      # 需要 clang>=18、libbpf-dev、bpftool、g++
# 或指定 BTF（kernel image 非目标内核时）:
scripts/build.sh --dev --vmlinux /path/to/vmlinux.h
```

## 目标环境（openEuler 24.03 LTS SP4）

```bash
scripts/env_check.sh --json evidence/env_check.json      # 1. 能力探测（含 PMU/CPPC）
scripts/build.sh --kernel-src /root/kernel-src --install # 2. 用目标内核 tools/sched_ext 构建
scripts/schedpilotctl.sh start --mode adaptive           # 3. 加载调度器 + 启动 daemon
scripts/schedpilotctl.sh status                          # 4. 状态
bench/abcd_experiment.sh --runs 20 --duration 60         # 5. A/B/C/D 交织实验
scripts/schedpilotctl.sh rollback                        # 6. 回退默认 fair 调度器
```

## A/B/C/D 与消融

| Arm | 含义 |
|---|---|
| A | 默认 fair baseline（sched_ext 未加载） |
| B | basic sched_ext（单 shared DSQ，无分类） |
| C | + 任务分类（LAT/COMP/CACHE 三类 DSQ，静态策略） |
| D | SchedPilot 全量自适应（分类 + 自适应 knob + LLC 亲和/迁移控制 + BG 收容 + 预抢占） |
| d-no-pmu / d-no-llc / d-no-bg | D 的 PMU 分类 / LLC 迁移控制 / BG 收容消融 |

收益归因由 `bench/analyze_results.py` 输出（B-A、C-B、D-C、D-A 及消融 vs D）。

## 安全与回退

- daemon 心跳超时（2s）→ BPF 自动降级为静态安全参数；loader 退出 → 自动回到默认 fair 调度器。
- 所有策略 knob 有上下界、generation 与异常写入保护；`schedpilotctl.sh rollback` 一键回退。
- 实验数据永久保留原始 CSV/JSON/调度器状态/PMU 计数/日志；不生成任何伪造数据，未完成项在测试报告中显式列出。

## 文档

- 总体方案与长期 roadmap：`SchedPilot_设计方案.md`
- MVP 范围：`docs/00_mvp_scope.md`
- 测试方案：`docs/02_test_plan.md`
- 部署与回滚：`docs/03_deploy_rollback.md`
- 测试报告（含真实探测与编译结果）：`docs/04_test_report.md`
