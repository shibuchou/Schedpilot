# SchedPilot v0.3 省赛 MVP 范围与验收

更新时间：2026-09-29
状态：实现中（本文件随落地进展更新）

## 1. MVP 范围（必做，阻塞项）

| # | 能力 | 验收方式 |
|---|---|---|
| 1 | 环境能力探测（OS/kernel/kernel config/BTF/CONFIG_SCHED_CLASS_EXT/clang/libbpf/bpftool/PMU/governor） | `scripts/env_check.sh --json`，含真实探测结果 |
| 2 | 真正的 BPF/sched_ext `SCX_OPS` 调度器，可加载/卸载/安全回退 | `scx_schedpilot` 加载后 `/sys/kernel/sched_ext/state=enabled`；kill 后回默认 fair |
| 3 | 三条核心 DSQ：LAT / COMP / CACHE；L-SYNC 短 slice+优先级+预抢占，C-COMPUTE 公平 vtime，M-BOUND 长 slice+LLC 软亲和+迁移惩罚 | `--stats` 计数与 cfg/日志可查 |
| 4 | 用户态 PMU 采样：cycles/instructions/cache-references/cache-misses，处理 multiplex `time_enabled/time_running` scaling | `schedpilotd` JSONL 中 `ipc`/`mpki` 特征与 `pmu_multiplexed` 标记 |
| 5 | eBPF 调度事件：wakeup / runtime / run delay 可持续采集 | `tg_stats` pinned map + JSONL 特征 |
| 6 | EWMA + hysteresis 三分类（L-SYNC/C-COMPUTE/M-BOUND），BG 仅显式配置标记 | JSONL 分类事件（特征+置信度+原因） |
| 7 | 慢控制回路（daemon）+ 快路径（BPF O(1) 查表）；knob 带上下界/generation/heartbeat/watchdog | `--dump-cfg`、policy 事件、异常注入测试 |
| 8 | Redis + CPU/内存干扰混部旗舰场景；客户端隔离 | 客户端固定 CPU + exclude 名单，见测试方案 |
| 9 | A/B/C/D 递进对照 + 消融（PMU 分类/LLC 迁移控制/BG 收容） | `bench/abcd_experiment.sh` 与 analyze 输出 |
| 10 | ≥20 次有效交织重复；统计 QPS/p50/p95/p99/p99.9/CPU/上下文切换/迁移/IPC/MPKI/overhead，报告中位数/IQR/均值/标准差/95% CI | `summary.md/summary.csv/per_run.csv` + 原始目录 |
| 11 | 省赛验收目标：真实 ACTIVE sched_ext 策略下 Redis 混部 P99 降低 ≥10% 或固定 SLO 下吞吐 +10%；无干扰 ±2% | 实验结论 + 归因链 |
| 12 | 部署/回滚说明、测试报告、演示一键流程 | 文档 + `schedpilotctl.sh` |

## 2. 明确不做（P1/P2/Future）

| 项 | 级别 | 说明 |
|---|---|---|
| CUSUM 相位检测 | P1 | MVP 不阻塞；分类器已保留滞后与置信度接口 |
| 贝叶斯/爬山自动调参 | P2 | MVP 仅规则型有界调整 |
| producer-consumer 自动识别 | P2 | MVP 用 waker-LLC 启发式替代 |
| 精确 NUMA remote/local memory access ratio | 不做宣称 | 仅允许表述为“基于当前 CPU NUMA node 与 /proc/[pid]/numa_maps 页面分布推断的 CPU-memory placement locality/mismatch” |
| 动态 BG CPU pool | P1 | MVP 仅显式标记 + vtime 降权收容 |
| RAPL / RPC / Kubernetes / 多负载全面适配 | Future | 不进入省赛范围 |

## 3. 未完成项记录规则

任何受硬件、PMU、kernel API、sched_ext backport 限制无法实现的能力，必须在本目录
`docs/04_test_report.md` 记录：**探测命令、实际输出、原因、降级方案、当前状态**。
禁止以设计或预期代替实际结果；禁止伪造性能数据。
