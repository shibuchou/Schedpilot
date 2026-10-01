# Changelog

## v0.3.0-mvp — 省赛最小闭环（2026-09-29 → 2026-10-01）

### 最终修复轮（三负载与稳定性）

- `exclude_names` 改精确匹配（修复 `mysqld` 被 "mysql" 前缀误排除）。
- 扫描目标纳入 `bg` 名单（修复 BG 任务从未标记的问题）。
- daemon 检测退化 LLC 拓扑（VM 每 vCPU 一个 L3 域）并关闭 waker-LLC 路由。
- 分类器 `first_update` 立即锁定；新增 `classifier.lat_moderate`（MySQL 关闭）。
- 非 LAT 唤醒预抢占（4× 阈值）；LAT 抗饥饿守卫；CACHE 迁移惩罚上限。
- **消除 sched_ext watchdog 失速**：修复前 nginx-1/mysql-1 期间 60 次 `runnable task stall`，
  修复后 nginx-2/mysql-2/soak 窗口 0 次（污染矩阵已作废并记录）。
- 场景 v3：Nginx/MySQL 服务与干扰同 CPU 集（与 Redis 口径统一）。

### 最终正式结果（场景 v3）

- **Redis（formal-2）**：D vs fair **+116.9% QPS**（p<0.0001），goodput@SLO +116.5%。
- **MySQL（mysql-2）**：D **+62.4% TPS、p99 −77.2%**（p<0.0001）。
- **Nginx（nginx-2）**：basic 模式（B）**+43.8% QPS、p99 −37.7%**（推荐；分类模式尾延迟为 P1 限制）。
- **外部对照（ext-1）**：scx_simple −49.7%（p99 +350%）、scx_flatcg +1.8%；SchedPilot D +118.9%。
- **无干扰回归（noif-1）**：C/D 吞吐 ±2% 内、p99 −13.2%、迁移 −95%。
- 故障注入 6/6、15/30 分钟 soak 通过、分类器单测通过、CI 就绪。

### 新增

- **BPF/sched_ext 数据面** `scx_schedpilot`：LAT/COMP/CACHE 三路 DSQ、waker-LLC 路由、
  迁移惩罚、LAT 唤醒预抢占、cfg（mode/flags/generation/心跳）、per-TGID 调度事件统计、
  心跳超时 fail-open。
- **用户态控制面** `schedpilotd`：per-TID PMU 采样（cycles/instructions/cache-refs/cache-misses，
  含 `time_enabled/time_running` multiplex scaling）、wakeup/runtime/run-delay 特征、
  EWMA + 非对称滞回三分类（L-SYNC/C-COMPUTE/M-BOUND，BG 显式标记）、有界自适应 knob、
  JSONL 可审查日志。
- **实验设施**：A/B/C/D + 三组消融编排（`bench/abcd_experiment.sh`）、
  Redis/Nginx/MySQL 三负载基准、固定 SLO goodput 统计（`analyze_results.py`）、
  外部对照调度器 scx_simple/scx_flatcg（`scripts/build_external.sh`）。
- **测试与交付**：故障注入（loader/daemon kill、rollback）、30 分钟 soak、分类器单元测试、
  GitHub Actions CI、一键演示（`scripts/demo.sh`）、状态页（`scripts/status_html.sh`）、
  submission 提交包。

### 修复（均有实验对照）

- wakeup 统计从 enqueue 迁移到 select_cpu（直投路径不经过 enqueue），修复 L-SYNC 无法触发。
- p99.9 解析兼容 redis-benchmark 非整数百分位；新增固定 SLO goodput。
- 分类器改为 wake 频率主判据 + 离开 L-SYNC 需 2× 滞回；自适应 knob 增加向默认值衰减与上限。
- `run_nginx.sh`/`run_mysql.sh` 的裸 `wait` 死锁修复（等待 perf 具体 PID）。

### 正式实验结果

- **formal-2**（场景 v2，7 臂 × 20 × 60s，140/140 有效）：D vs 默认 fair **+116.9% QPS**
  （p<0.0001），固定 SLO(5ms) goodput +116.5%；p50 3.37ms→0.50ms。
- 归因：sched_ext 本身 +69.0%、分类 +24.8%、自适应 +2.9%；关 LLC/迁移控制 −3.4%。
- **noif-1**（无干扰回归，10 × 60s）：C/D 吞吐 ±2% 内、p99 −13.2%；迁移次数 −95%。
- **formal-1**（v1 轻干扰）保留为负结果对照；全部原始数据可追溯。
