# SchedPilot 省赛 MVP 测试方案（v0.3）

## 1. 环境与基线口径

- 主开发与性能测试环境：openEuler 24.03 LTS SP4（冻结）。
- 内核：SP4 上启用 `CONFIG_SCHED_CLASS_EXT` 的内核（发行版内核未启用时使用自编译内核；
  EulerPilot 已完成过同平台自编译验证，SchedPilot 复用同一路径）。
- Baseline 统一表述：**openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）**。
  不假设 Linux 6.6 fair-class 内部实现与 mainline 经典 CFS 相同；所有比较以同机同 kernel 的 A 臂实测为准。
- 固定项：硬件、kernel、governor(performance)、CPU 亲和、Redis 参数、干扰参数、预热时间、稳态窗口。
- 每次实验记录：git commit、kernel 版本、完整命令、调度器状态、cfg、PMU 原始计数、dmesg。

## 2. 旗舰场景：Redis + 干扰混部

- Redis：`bench/redis-schedpilot.conf`（port 6399，io-threads 1，AOF/RDB 关闭，maxmemory 2gb）。
- Workload：`redis-benchmark -t get -c 50`，请求数按预跑估算使稳态窗口 ≈ `--duration`；
  解析 REDIS 输出的 throughput summary（QPS）与 latency summary（avg/min/p50/p95/p99/max），
  p99.9 从 percentile distribution 段解析。
- 干扰：**正式场景定义 v3（2026-10-01 起，统一口径）**：
  `stress-ng --cpu 4 --cpu-method matrixprod --vm 2 --vm-bytes 1G` 与业务服务**同 CPU 集（0-3）**，
  形成真实同核竞争；客户端固定在 4-7 并明确排除出分类目标。
  - Redis：`redis-server` pinned 0-3（自始即为此口径，formal-2 即 v3 等效）；
  - Nginx：master+workers pinned 0-3（`bench/abcd_experiment.sh` 自动设置）；
  - MySQL：`mysqld` 全部线程 pinned 0-3（同上）。
  - 历史数据：nginx-1/mysql-1（v2 浮动场景、修复前二进制）已被 scx watchdog 失速证据判定为受污染，
    仅保留为缺陷证据（见 `docs/04_test_report.md` §6.9），不作为结论依据。
- 无干扰回归：使用 `--no-interference` 单独跑 A/B/C/D。
- 客户端隔离（单机模式强制）：`redis-benchmark` 固定到独立 CPU（如 `4-7`），
  并通过配置 `exclude_names` 明确排除出 SchedPilot 分类/调度目标，避免客户端调度变化污染结论。
  有条件时优先使用独立客户端机器发压。

## 3. PMU 采样与 multiplex scaling

- 每 TGID 枚举线程，逐线程 `perf_event_open` 组：
  `cycles, instructions, cache-references, cache-misses`，`inherit=1`，
  `read_format = GROUP|TOTAL_TIME_ENABLED|TOTAL_TIME_RUNNING`。
- 差值换算：`scaled = raw_delta * time_enabled_delta / time_running_delta`（128 位中间量），
  并在 JSONL 中标记 `pmu_multiplexed`。
- 特征：`IPC = instructions/cycles`；`MPKI = cache-misses/instructions*1000`。
- 降级：PMU 不可用（VM 无 vPMU、perf_event_paranoid 过高、权限不足）时记录原因，
  分类器退回调度事件特征（L-SYNC 仍可判定，其余归 NORMAL），在日志与报告中显式标注。

## 4. A/B/C/D 与消融

| Arm | 调度器 | 分类 | 自适应 | LLC 迁移控制 | BG 收容 | 预抢占 |
|---|---|---|---|---|---|---|
| A | 无（默认 fair） | - | - | - | - | - |
| B | basic scx（shared DSQ） | 关 | 关 | 关 | 关 | 关 |
| C | 三类 DSQ | 开（静态策略） | 关 | 开（默认） | 开（默认） | 开（默认） |
| D | 三类 DSQ | 开 | 开 | 开 | 开 | 开 |
| d-no-pmu | 同 D | 仅调度特征 | 开 | 开 | 开 | 开 |
| d-no-llc | 同 D | 开 | 开 | 关 | 开 | 开 |
| d-no-bg | 同 D | 开 | 开 | 开 | 关 | 开 |

> ⚠️ **LLC 迁移控制一列有个陷阱**：C/D 标的是"开（默认）"，但 daemon 会在**检测到 LLC 拓扑退化时
> 自动关闭**该路由（KVM 客户机上常见，每个 vCPU 暴露独立 cache 域，日志会打
> `degenerate LLC topology ... disabling waker-LLC routing`）。SP4 演示 VM 上实测即为此情况：
> 因此 `d-no-llc` 臂与 D 臂的 cfg flags 完全相同（均为 27），**该 VM 上不构成有效对照**（见 `docs/06` S2）。
> 有效的机制消融是 `d-no-bg`（flags 19 vs 27）。

- 交织执行：每轮按旋转顺序运行各臂，20 次有效重复（无效轮次必须记录原因并补齐）。
  **例外：最终 MySQL 矩阵（`mysql-3`）为 n=10**（受机器时间限制），已在 `docs/04` §6.10 与证据索引中标注。
- 每臂每轮：切换后稳定 2s → 干扰 2s → 预热（默认 10s，不计入）→ 稳态测量（默认 60s）。

## 5. 指标与统计

- 吞吐：QPS（中位数、IQR）。
- 延迟：p50/p95/p99/p99.9（同口径解析）。
- 资源：Redis 进程 context-switches、cpu-migrations、IPC、MPKI（perf stat）；CPU 利用率（proc_stat 前后差值）。
- 调度器开销：daemon CPU 时间（/proc/self/stat 快照）、BPF dispatch 计数、`schedpilotd --status`。
- 统计：中位数、IQR、均值、标准差、95% CI（t 近似）。
- **口径更新（2026-10-01 起，已生效）**：吞吐类结论以**逐轮配对复算**为准
  （mean Δ% + 95% CI + 更高/更低轮数）；Mann-Whitney U 的 p 值**仅用于延迟指标**。
  原先"组间 Mann-Whitney U（p 值）"的写法已废止，见 `docs/04` §6.7 的口径更正说明。
- 归因链：B-A（sched_ext 本身）、C-B（分类）、D-C（自适应）、D-A（总计）、消融 vs D。

## 6. 验收门槛

1. Redis 混部场景：**P99 降低 ≥10%** 或 **固定 P99 SLO 下 QPS 提升 ≥10%**（D vs A），统计显著（p<0.05 且 CI 支持）。
2. 无干扰场景（`--no-interference`）：D vs A 在 ±2% 以内，无显著退化。
   **实测未达（如实记录）**：`noif-2` C −3.20%、D −3.28%（10/10 轮为负）、B −5.67%。
   结论改述为"无干扰下以约 3% 吞吐换取约 12% 尾延迟改善"，见 `docs/04` §6.8。
3. 归因可证：map/DSQ dispatch/分类事件/策略更新日志/原始数据/消融结果齐全。
4. 稳定性：连续 20 轮无 watchdog 触发、无 daemon 崩溃、每轮后 `schedpilotctl.sh rollback` 可回退。

## 7. 复现入口

```bash
scripts/env_check.sh --json evidence/env_check.json
scripts/build.sh --kernel-src "$KSRC" --install
bench/abcd_experiment.sh --runs 20 --duration 60 --results results/$(date +%Y%m%d-%H%M%S)
```
