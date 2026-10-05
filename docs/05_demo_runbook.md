# SchedPilot 10 分钟演示流程（评审现场版）

本流程在实验 VM（`schedpilot-sp4`，openEuler 24.03 LTS SP4 + `6.6.0-schedpilot` 内核）上按顺序执行：
**项目怎么运转（1 分钟）→ 混部优势实验（3 分钟）→ 分类实况（1 分钟）→ 安全兜底（1 分钟）→ 收尾（30 秒）**，
命令总计约 3 分钟，配合讲解控制在 **10 分钟以内**。所有命令均可直接复制执行（工作目录 `/root/schedpilot`）。

> 讲解主口径：同 CPU 干扰混部下，SchedPilot 全自适应模式（D）相对 openEuler 默认 fair 调度器（A）
> **QPS +160% 量级、p99 −35%**（正式 20 轮统计口径：QPS 配对 **+169.8% [164.4, 175.2]，20/20 轮更高**，
> p99 −34.7%；见 `docs/04_test_report.md` §6.10）。演示现场用 1 轮快速对比展示趋势。

---

## 时间轴

| 段 | 命令耗时 | 内容 |
|---|---|---|
| 0 环境自检 | ~5s | `env_check`：sched_ext/BTF/PMU/工具链全绿 |
| 1 一条命令上线 | ~10s | 加载调度器 + 状态 + 数据面统计（实时计数器） |
| 2 优势实验 | ~100s | `demo.sh 30 1`：A（默认 fair）vs D（SchedPilot）干扰混部对比 |
| 3 分类实况 | ~10s | 从运行日志看 L-SYNC / BG / M-BOUND 实时分类 |
| 4 安全兜底 | ~20s | 杀 loader → 自动回默认 fair；杀 daemon → 调度器保持在线（fail-open） |
| 5 收尾 | ~10s | rollback + dmesg 无 watchdog/stall |
| 6 讲解缓冲 | ~4min | 三段讲解词 + 答疑 |

---

## 0. 环境自检（约 5 秒）

```bash
cd /root/schedpilot
scripts/env_check.sh | tail -n 8
```

期望输出（真实捕获）：

```
[OK] workload.sysbench            /usr/bin/sysbench
[OK] workload.stress-ng           /usr/bin/stress-ng
[OK] schedpilot.loader            /root/schedpilot/build/scx_schedpilot
[OK] schedpilot.daemon            /root/schedpilot/build/schedpilotd
[OK] schedpilot.pinned_maps       cfg class_map cpu_llc stats tg_stats
=== summary: OK=34 WARN=1 FAIL=0 ===
```

**讲解词**：这套环境是 openEuler 24.03 LTS SP4 + 自编译启用 `CONFIG_SCHED_CLASS_EXT` 的 6.6 内核；
`sched_ext`、BTF、PMU、clang/libbpf 工具链全部就绪，0 个 FAIL。

---

## 1. 一条命令上线（约 10 秒）

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
scripts/schedpilotctl.sh status
build/scx_schedpilot --stats | head -n 3
```

期望输出（真实捕获）：

```
[schedpilot] starting scx_schedpilot --mode adaptive
[schedpilot] sched_ext state=enabled ops=schedpilot
[schedpilot] starting schedpilotd --config configs/redis.conf
[schedpilot] started (mode=adaptive)
...
cfg mode=2 generation=2 flags=0x1b hb_seq=25 ...
{"mode":2,"generation":2,"flags":27,...,"class_map_entries":0,"pmu_available":true,...}
```

**讲解词**：一条命令拉起"数据面 + 控制面"：

- **数据面**（eBPF，`scx_schedpilot`）：LAT / COMP / CACHE 三条 DSQ；L-SYNC 任务短切片+优先派发+唤醒预抢占，
  计算型走 vtime 公平，内存型长切片+LLC 软亲和+迁移惩罚；cfg 由用户态写入并带 generation + 心跳校验，
  **心跳超时自动回退到静态安全参数（fail-open）**。
- **控制面**（用户态 `schedpilotd`）：每 100ms 用"调度事件（唤醒率/运行时长/run delay/上下文切换）+
  PMU（IPC/LLC MPKI）"做 EWMA+滞回三分类（L-SYNC / C-COMPUTE / M-BOUND，BG 显式标记），
  只调有界的切片/惩罚旋钮。

---

## 2. 优势实验：干扰混部 A vs D（约 100 秒）

```bash
scripts/demo.sh 30 1
```

`demo.sh` 自动完成：自检 → 启动 Redis + stress-ng CPU/内存干扰（服务与干扰同 CPU 0-3，客户端隔离 4-7）
→ A 轮（默认 fair）→ D 轮（SchedPilot 全自适应）→ 汇总 → 回滚。

查看结果：

```bash
sed -n '1,16p' $(ls -td results/demo-* | head -n1)/summary.md
```

期望输出（真实捕获，1 轮示意）：

| arm | QPS | QPS Δ | p99 | p99 Δ |
|---|---|---|---|---|
| A（默认 fair） | 19466.77 | +0.0% | 4.423 ms | +0.0% |
| **D（SchedPilot）** | **50538.61** | **+159.6%** | **2.887 ms** | **−34.7%** |

**讲解词**：同一台机器、同一负载、同一干扰，唯一变量是调度器。默认 fair 下 Redis 被 4 个 CPU 干扰进程
和内存回收拖住（实测只拿到 16.7% 的 CPU 时间）；SchedPilot 把 Redis 主线程识别为 L-SYNC 走短片高优先，
干扰进程标记为 BG 用 vtime 惩罚+短切片收容，**吞吐翻 2.6 倍的同时尾延迟反而降三成**。
正式矩阵为 7 臂 × 20 轮 × 60 秒（含 3 组消融），QPS 配对 +169.8%、20/20 轮全部更高。

---

## 3. 分类实况（约 10 秒，可插在实验后）

```bash
RUN=$(ls -td results/demo-* | head -n1)
LOG=$(ls $RUN/D/run-01/logs/schedpilotd-*.jsonl | head -n1)
grep -m 2 '"class":"L-SYNC"' "$LOG" | cut -c1-220
grep -m 2 '"class":"BG"'     "$LOG" | cut -c1-220
grep -o '"class":"[A-Z-]*"'  "$LOG" | sort | uniq -c
```

期望输出（真实捕获）：

```
{"type":"sample",...,"comm":"redis-server","class":"L-SYNC","confidence":1.000,...,"pmu_valid":true,...}
{"type":"sample",...,"comm":"stress-ng","class":"BG","confidence":1.0,"source":"external","bg":true}
   3690 "class":"BG"
    375 "class":"L-SYNC"
     65 "class":"M-BOUND"
```

**讲解词**：每一次分类决策都落 JSONL 日志，特征、置信度、变更原因全部可审计——
Redis 被识为 L-SYNC（高唤醒率+高 IPC），stress-ng 是显式 BG，M-BOUND 是短暂出现的批处理线程。
分类不是"黑盒"，现场可逐条对质。

---

## 4. 安全兜底演示（约 20 秒）

**4a. 杀 loader → 内核自动回默认 fair：**

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
L=$(pgrep -f 'scx_schedpilot --mode' | head -n1); echo "loader=$L"
kill -9 "$L"; sleep 2
cat /sys/kernel/sched_ext/state          # 期望: disabled
```

期望输出（真实捕获）：

```
loader=264774
disabled
```

**4b.（可选）杀 daemon → 数据面 fail-open 保持在线：**

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
D=$(pgrep -f 'build/schedpilotd' | head -n1); kill -9 "$D"; sleep 3
cat /sys/kernel/sched_ext/state          # 期望: enabled（BPF 使用静态安全参数）
```

**讲解词**：调度器是内核里最"能出事"的位置，所以做了双层兜底：用户态 loader 挂掉 → `sched_ext`
自动 detach、默认 fair 接管（业务无损）；用户态 daemon 挂掉 → BPF 数据面保持启用并用静态安全参数运行
（心跳过期自动降级），daemon 重启后 100ms 内恢复。故障注入测试 6/6 通过。

---

## 5. 收尾（约 10 秒）

```bash
scripts/schedpilotctl.sh rollback
cat /sys/kernel/sched_ext/state              # disabled
dmesg | grep -a sched_ext | tail -n 3        # 无 watchdog/stall
```

**讲解词**：一键回滚；整个矩阵 0 次 watchdog/失速（对照：把内核树示例 scx_flatcg 放到同一场景会被
内核看门狗卸载 10/10 次）。

---

## 附：如果要现场跑正式口径

```bash
# Redis 旗舰矩阵：7 臂 × 20 轮 × 60 秒（约 3 小时，自动记录 commit/哈希/场景并 fail-fast）
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/demo-full
```

预期（与 `evidence/sp4-vm/formal-4/summary.md` 一致）：**D QPS +172.5%（配对 +169.8%，20/20 轮更高）、
goodput@SLO +173.1%、p99 −35.0%**。

## 附：首次使用前提

```bash
# 1) 构建（在目标环境执行一次；本 VM 已构建）
KSRC=/usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64
scripts/build.sh --kernel-src "$KSRC" --install
# 2) 依赖：redis-server（bench 自动启动）、stress-ng、sysbench（MySQL 可选）
```

## 现场应急预案

| 情况 | 处置 |
|---|---|
| D 轮数值异常波动（宿主噪声） | 重跑一次 `scripts/demo.sh 30 1`；正式统计以 20 轮矩阵为准 |
| 端口/进程残留 | `scripts/schedpilotctl.sh rollback; bench/interference.sh stop; pkill -f abcd_experiment` |
| 需要展示 MySQL/Nginx | `bench/abcd_experiment.sh --workload mysql --runs 5 --duration 30 --arms A,D --results results/demo-mysql`（Nginx 同理，约 5 分钟） |
| 大屏想看实时计数器 | 另开终端：`watch -n1 'cat /sys/kernel/sched_ext/state; build/scx_schedpilot --stats | head -n2'` |
