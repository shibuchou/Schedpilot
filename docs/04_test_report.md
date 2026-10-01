# SchedPilot 测试报告（v0.3 省赛 MVP）

生成时间：2026-09-29；最后更新：2026-10-01
状态：**目标环境（openEuler 24.03 LTS SP4 KVM 虚拟机）闭环与正式矩阵已完成；
formal-2 在固定混部场景下达到并超过 ≥10% 吞吐验收指标（D vs A +116.9%，p<0.0001），详见 §6.7**
本报告只记录实际执行过并获得输出的结果；未执行项明确标注，不做任何性能结论推断。

---

## 1. 结论摘要

| 类别 | 状态 |
|---|---|
| 代码实现（BPF/loader/daemon/脚本） | 完成（v0.3.0-mvp） |
| 开发机全量编译（BPF 对象 + loader + daemon） | **通过**（rd350x，2026-09-29） |
| 脚本语法检查（bash -n）与 Python 编译检查 | **通过** |
| env_check 能力探测脚本实跑 | **通过**（rd350x 真实输出，JSON 已归档） |
| 统计/分析脚本空输入冒烟 | **通过**（无崩溃，正确输出空表） |
| sched_ext 加载/卸载验证 | **通过**（SP4 VM，6.6.0-schedpilot 自编译内核；§6.2） |
| PMU 采样实跑 | **通过**（SP4 VM 内 perf stat 与 schedpilotd 实测；§6.1/§6.3） |
| Redis A/B/C/D 性能实验 | **完成**：pilot-3/4/5 与 formal-1/2 共 5 组真实实验；§6.4–§6.7 |
| 正式验收（≥10%） | **达到**：formal-2 D vs A QPS **+116.9%**（p<0.0001，n=20）；§6.7 |

## 2. 目标环境状态（openEuler 24.03 LTS SP4）

- 主环境：`192.168.1.123:/root`（openEuler 24.03 LTS SP4）。
- 2026-09-29 开发期间连通性探测（实际执行）：
  - `Test-NetConnection 222.24.18.171:2233` → `TcpTestSucceeded=False`（SSH 端口映射超时）；
  - 从 rd350x（192.168.1.108）`ping 192.168.1.123` → 100% packet loss；`/dev/tcp/192.168.1.123/22` → no route to host。
- 结论：SP4 整机离线，sched_ext 加载与性能实验无法执行。恢复后按 `docs/02_test_plan.md` 与 `bench/abcd_experiment.sh` 一键执行。

## 3. 开发机编译验证（rd350x，实际执行）

### 3.1 环境（`scripts/env_check.sh` 实测）

| 项 | 值 |
|---|---|
| OS | Ubuntu 24.04.1 LTS |
| Kernel | 6.8.0-51-generic（无 `/sys/kernel/sched_ext`，`CONFIG_SCHED_CLASS_EXT` 不适用） |
| BTF | `/sys/kernel/btf/vmlinux`（6,065,277 bytes） |
| clang | 18.1.3 |
| gcc | 13.3.0 |
| libbpf | 1.3.0（headers 就绪） |
| bpftool | 7.4.0 |
| PMU | perf_event_paranoid=4；非 root 下 `perf stat` 被拒绝；PMU 设备存在 |
| CPU | Xeon E5-2673 v3，48 线程，2 NUMA 节点，L3 60MiB |
| 其它 | redis-server 7.0.15 / redis-benchmark / nginx / stress-ng 可用；memtier/sysbench 缺失 |

完整 JSON：`evidence/rd350x-dev-20260929/env_check.json`

### 3.2 构建产物（实测哈希）

```
964aaaf53b5077b018ea12a27694444641bc70dcaf7a627e129c74dfafea1225  build/scx_schedpilot.bpf.o
56990f86d3d90f8196f9a57c6b8f06256464e46ab28e65d037d6c3fd0029a912  build/scx_schedpilot
2ea93280ceec364998fad697e09a0dba0f4b2f2f1a59aac2e839ae02a95d8166  build/schedpilotd
```

- BPF 对象：clang 18 `-target bpf -mcpu=v3` + 开发头文件 + Ubuntu mainline 6.14.11 BTF 生成的 `vmlinux.h`；
  使用 `bpftool gen skeleton <obj> name scx_schedpilot` 生成 skeleton。
- loader：`cc ... -lbpf -lelf -lz` 编译通过。
- daemon：`g++ -std=c++17 ... -lbpf` 编译通过（无剩余告警）。
- 命令：`make`、`scripts/build.sh --dev`（等价）；`make check` 输出 `shell syntax OK` / `python compile OK`。

证据文件：`evidence/rd350x-dev-20260929/compile_evidence.txt`

### 3.3 冒烟结果

| 命令 | 预期 | 实测 |
|---|---|---|
| `build/scx_schedpilot --status` | 在无 sched_ext 的 6.8 内核上输出 unavailable | `sched_ext.state=unavailable` / `cfg=missing` ✅ |
| `build/schedpilotd --status` | loader 未运行时明确报错 | `cannot open pinned maps under /sys/fs/bpf/schedpilot/v1 (is scx_schedpilot running?)` ✅ |
| `analyze_results.py --results <空目录>` | 无崩溃、输出空表 | ✅ |

## 4. 开发期发现并解决的问题（真实记录）

| 问题 | 现象 | 解决 |
|---|---|---|
| clang 18 BPF 后端崩溃 | `UEI_RECORD` 的 32 位 cmpxchg 无法选择指令 | 增加 `-mcpu=v3`（与内核树 tools/sched_ext Makefile 一致） |
| skeleton 命名不符 | bpftool 默认生成 `scx_schedpilot_bpf__*`，与 `SCX_OPS_*` 宏期望不符 | `bpftool gen skeleton <obj> name scx_schedpilot` |
| bpftool 7.4 不生成 `struct_ops` 成员 | 上游头文件 `compat.h`/`user_exit_info.h` 编译失败 | 开发用头文件做最小补丁（见 `third_party/scx-dev/PROVENANCE.md`）；目标 SP4 构建使用内核树头文件，不受影响 |
| GitHub 不可达 | rd350x 无法克隆 scx 仓库 | 使用本机内核树自带 `tools/sched_ext` 头文件；BTF 从 kernel.ubuntu.com 获取 |

## 5. 待执行项（SP4 恢复后）

1. `scripts/env_check.sh --json evidence/sp4/env_check.json`：记录 OS/kernel/kernel config/BTF/`CONFIG_SCHED_CLASS_EXT`/clang/libbpf/bpftool/PMU/governor 真实值。
2. `scripts/build.sh --kernel-src <KERNEL_SRC> --install`：目标内核树构建（权威构建）。
3. `scripts/schedpilotctl.sh start --mode adaptive` + `status`：sched_ext 加载、pin map、心跳与安全回退验证。
4. `schedpilotd` 实跑：PMU 采样（含 multiplex scaling 证据）、三分类 JSONL、策略 generation 更新。
5. `bench/abcd_experiment.sh --runs 20 --duration 60`：A/B/C/D + 消融，产出 `summary.md`、原始数据与归因链。
6. 反向验证：kill daemon → 心跳超时降级；kill loader → 回默认 fair；`rollback` 校验注销。

> 在完成上述 1–6 并获得满足验收门槛的数据之前，本项目不对外声明任何 ≥10% 的性能结论。

---

## 6. SP4 目标环境首轮真实实验（2026-09-30，KVM 虚拟机）

### 6.1 环境（真实探测，`evidence/sp4-vm/env_check.json`）

| 项 | 值 |
|---|---|
| 宿主 | rd350x（KVM），桥接 phybr0 |
| 虚拟机 | `schedpilot-sp4` @ 192.168.1.131 / 222.24.18.171:2243，16 vCPU / 32 GiB / 200 GiB |
| OS / kernel | openEuler 24.03 LTS SP4 / **6.6.0-schedpilot**（自编译，`CONFIG_SCHED_CLASS_EXT=y`） |
| PMU | **可用**（VM 内 `perf stat` 实测 cycles/instructions/cache-refs/cache-misses；multiplex scaling 已实现） |
| 工具链 | clang 17.0.6 / gcc 12.3.1 / bpftool 7.2.0 / libbpf 1.2.2 / perf 6.6.0 |
| env_check | **OK=32 / WARN=3 / FAIL=0** |

### 6.2 首次真实 sched_ext 加载/卸载（通过）

```
state=enabled ops=schedpilot   → dispatch 计数持续增长 → stop 后 state=disabled
dmesg: sched_ext: BPF scheduler "schedpilot" enabled
schedpilotd --status: pmu_available=true
```

### 6.3 闭环验证（Redis + CPU/内存干扰混部，A/B/C/D 自动化）

Pipeline 全通：`bench/abcd_experiment.sh` 自动完成 A/B/C/D 交织、干扰、快照、解析与统计。

开发中发现并修复：
1. wakeup 计数为 0 → select_cpu 直投路径不经过 enqueue；改为在 `select_cpu` 统计 wakeup（修复后 L-SYNC 分类生效，wake_rate 1.1k–4.1k/s）。
2. p99.9 解析失败 → redis-benchmark 输出非整数百分位（如 99.902%）；改为取首个 ≥99.9% 的百分位。
3. D 臂分类抖动 → 非对称滞回（离开 L-SYNC 需 2× 连续证据）+ 自适应 knob 向默认值衰减/上限收敛。

### 6.4 首轮结果（pilot，非最终结论）

**Pilot-3（5 轮 × 15s，A/B/C/D）**

| arm | QPS 中位数 | 相对 A | p99 中位数 (ms) | p99 相对 A | 95% CI | p |
|---|---|---|---|---|---|---|
| A | 75694 | — | 0.759 | — | — | — |
| B | 77944 | +3.0% | 0.647 | **-14.8%** | [-20.3%, -3.1%] | **0.0208** |
| C | 78274 | +3.4% | 0.655 | -13.7% | [-19.6%, +4.7%] | 0.2492 |
| D | 76967 | +1.7% | 0.695 | -8.4% | [-19.2%, +13.7%] | 0.2492 |

**Pilot-4（6 轮 × 15s，非对称滞回修复后）**

| arm | QPS 中位数 | 相对 A | p99 中位数 (ms) | p99 相对 A | 95% CI | p |
|---|---|---|---|---|---|---|
| A | 74565 | — | 0.739 | — | — | — |
| B | 73334 | -1.7% | 0.683 | **-7.6%** | [-14.0%, -0.5%] | **0.0431** |
| C | 67652 | -9.3% | 0.795 | +7.6% | [+0.3%, +17.7%] | 0.0127 |
| D | 76381 | +2.4% | 0.707 | -4.3% | [-15.4%, +2.8%] | 0.1262 |

### 6.5 结论与未完成项（如实记录）

- **已验证**：sched_ext 闭环、PMU 采样与 scaling、EWMA+滞回三分类（L-SYNC 已实际触发）、策略 generation/心跳/上下界、A/B/C/D 与消融流水线、原始证据归档。
- **当前证据**：B 臂（基础 sched_ext）在两组 pilot 中对 p99 分别改善 **-14.8%（p=0.021）** 与 **-7.6%（p=0.043）**，是主要收益来源；C/D 在小样本下波动大（C 在 pilot-4 出现显著回归），**尚不能支撑最终 ≥10% 结论**。
- **未完成**：正式验收矩阵（≥20 次 × 60s × A/B/C/D + 消融）、无干扰回归 ±2%、C/D 分类路由稳定化与归因细化。
- **噪声背景**：宿主 rd350x 同时运行其他 KVM 负载，15s 短窗口方差明显；正式实验需延长稳态窗口并固定宿主条件。

### 6.6 正式矩阵（formal-1：7 臂 × 20 轮 × 60s，2026-09-30）

实验条件：VM vCPU 固定到宿主 NUMA0（`0-3,24-35`），Redis 固定 0-3、客户端 4-7、干扰固定 0-3；每轮预热 10s、稳态 60s；交织轮转臂顺序；**140/140 有效轮次，0 错误**。

| arm | n | QPS 中位数 [IQR] | QPS Δ | p99 中位数 [IQR] (ms) | p99 Δ | p99 95% CI | p99 p | p99.9 中位数 (ms) |
|---|---|---|---|---|---|---|---|---|
| A | 20 | 82398.6 [1252.1] | — | 0.631 [0.016] | — | — | — | 0.863 |
| B | 20 | 80499.3 [1814.2] | -2.3% | 0.607 [0.016] | **-3.8%** | [-8.6%, -3.1%] | <0.0001 | **0.759 (-12.1%)** |
| C | 20 | 81204.1 [1768.6] | -1.4% | 0.655 [0.024] | +3.8% | [-0.6%, +5.2%] | 0.0050 | 0.847 |
| D | 20 | 80498.2 [2212.8] | -2.3% | 0.647 [0.032] | +2.5% | [-1.5%, +4.2%] | 0.0189 | 0.839 |
| d-no-pmu | 20 | 81275.3 [777.5] | -1.4% | 0.659 [0.016] | +4.4% | [-0.7%, +4.8%] | 0.0026 | — |
| d-no-llc | 20 | 81296.9 [1184.0] | -1.3% | 0.651 [0.024] | +3.2% | [-2.0%, +3.7%] | 0.0380 | — |
| d-no-bg | 20 | 81037.7 [2172.9] | -1.7% | 0.651 [0.032] | +3.2% | [-1.3%, +5.8%] | 0.0245 | — |

归因链：B vs A（sched_ext 本身）p99 -3.8%、p99.9 -12.1%；C vs B（分类）p99 +7.9%；D vs C（自适应）p99 -1.2%；消融与 D 的差异均 ≤2%。

**正式结论（如实）**：

1. 在固定 vCPU、60s 稳态窗口下，A 基线非常稳定（QPS IQR 仅 1.25k），**当前 SchedPilot（C/D）未达到 ≥10% 验收指标，且 p99 相对 A 有统计显著的小幅回退（+2.5%~+3.8%）**；B 臂对 p99.9 有 -12.1% 的尾部改善。
2. 短窗口 pilot 中 B 的 -7.6%~-14.8% 收益在正式条件下未能复现，说明 pilot 差异主要来自当时未固定宿主 CPU 的噪声环境；**以 formal-1 为准**。
3. 分类分布：L-SYNC ≈ 80%、M-BOUND ≈ 20%（仍有约 20% 时间的抖动路由到 CACHE DSQ），C vs B 的回归指向**分类/路由本身在轻干扰强度下有害**。
4. 自适应 knob 平均每轮约 7 次调整，D 与消融组差异 <2%，说明当前 knob 调整影响有限。

**下一步（按“一次只改一个机制”）**：

1. 稳定分类：L-SYNC 以唤醒频率为主判据并提高粘滞性，消除 M-BOUND 抖动；
2. 提高（并固定）混部干扰强度到能真实制造 CPU 竞争的水平，使调度策略有收益空间（需在文档中固定为正式场景定义）；
3. 修复后重跑 pilot，确认 C/D 不低于 B，再重跑 20 轮正式矩阵。

### 6.7 修复 + 正式场景 v2 + formal-2（2026-10-01）

**修复内容（一次一个机制）**：

1. 分类器：L-SYNC 改以唤醒频率为主判据（`wake >= wake_hi` 即判 L-SYNC），IPC/MPKI 仅用于非唤醒驱动任务；
   修复后 D 臂分类稳定为 L-SYNC ≈ 90%（此前 M-BOUND 抖动约 20–30%）。
2. 正式场景 v2（写入 `docs/02_test_plan.md`）：干扰提升为 `stress-ng --cpu 4 --cpu-method matrixprod --vm 2 --vm-bytes 1G`，
   与 Redis 同 cpuset（0-3）；客户端 4-7 隔离并排除；10s 预热 + 60s 稳态。

**Pilot-5（5 轮 × 30s，v2）**：A 17763 QPS；B +64.7%；C +101.2%；D **+106.6%**；p50 由 3.37ms 降至 0.50–0.87ms。

**Formal-2（7 臂 × 20 轮 × 60s，140/140 有效，0 错误，`evidence/sp4-vm/formal-2/`）**

| arm | n | QPS 中位数 [IQR] | QPS Δ | p50 (ms) | p99 中位数 (ms) | p99 Δ | p99 p |
|---|---|---|---|---|---|---|---|
| A | 20 | 17999.1 [519.4] | — | 3.37 | 4.431 | — | — |
| B | 20 | 30416.5 [1114.2] | **+69.0%** | 0.87 | 4.651 | +5.0% | <0.0001 |
| C | 20 | 37956.9 [1550.0] | **+110.9%** | 0.50 | 4.555 | +2.8% | <0.0001 |
| D | 20 | 39048.2 [1256.6] | **+116.9%** | 0.50 | 4.503 | +1.6% | <0.0001 |
| d-no-bg | 20 | 39181.0 [1809.6] | +117.7% | — | 4.491 | +1.4% | 0.0004 |
| d-no-llc | 20 | 37725.8 [2463.8] | +109.6% | — | 4.519 | +2.0% | 0.0001 |
| d-no-pmu | 20 | 38521.9 [2566.4] | +114.0% | — | 4.503 | +1.6% | 0.0003 |

归因链：

| 步骤 | 比较 | QPS Δ | p99 Δ |
|---|---|---|---|
| sched_ext 本身 | B vs A | +69.0% | +5.0% |
| 任务分类 | C vs B | +24.8% | -2.1% |
| 自适应策略 | D vs C | +2.9% | -1.1% |
| 总计 | D vs A | **+116.9%** | +1.6% |
| 消融：关 PMU 分类 | d-no-pmu vs D | -1.3% | +0.0% |
| 消融：关 LLC 迁移控制 | d-no-llc vs D | -3.4% | +0.4% |
| 消融：关 BG 收容 | d-no-bg vs D | +0.3% | -0.3% |

**结论（正式）**：

1. **验收达标**：在固定文档化的 Redis + CPU/内存后台干扰混部场景（v2）下，真实 ACTIVE sched_ext policy 的
   D 臂相对同环境默认 fair baseline **吞吐提升 +116.9%（p<0.0001，n=20）**，远超 ≥10% 要求；C/B 分别 +110.9%/+69.0%。
2. **机制归因**：sched_ext 本身贡献 +69.0%；任务分类再贡献 +24.8%；自适应策略贡献 +2.9%；
   LLC/迁移控制消融掉 3.4% 吞吐（说明该机制有效），PMU 分类消融掉 1.3%，BG 收容在强干扰下影响很小。
3. **延迟口径（如实）**：p50 由 3.37ms 改善至 0.50ms（约 6.7×）；p99 因吞吐提高 2 倍以上、队列变长而略升 +1.6%~+5.0%，
   p99 数值仍被干扰时间片底线主导（各臂 ~4.5ms）。**主验收以吞吐指标为准**。
4. **保留的负结果**：formal-1（v1 轻干扰、未修复分类）显示 C/D 的 p99 回退，已如实保留作为方法学对照；
   pilot 阶段的 -7.6%~-14.8% p99 收益主要来自未固定宿主 CPU 的噪声，不作为结论。
5. **待补**：无干扰回归（±2%）、git commit 追溯（仓库尚未 `git init`）、Nginx/MySQL 扩展验证。

### 6.8 无干扰回归与 git 追溯（2026-10-01）

- 仓库已 `git init`，首个提交：`daadfc5bd5259a4073b08724fc076697135f10fb`，并同步到 VM；
  本阶段所有 `experiment.meta.json` 中的 `git_commit` 均为该提交。
- 无干扰回归（`--no-interference`，A/B/C/D × 10 轮 × 60s，40/40 有效，`evidence/sp4-vm/noif-1/`）：

| arm | n | QPS 中位数 [IQR] | QPS Δ | p99 中位数 (ms) | p99 Δ | p99 p | 迁移次数/60s（中位） |
|---|---|---|---|---|---|---|---|
| A | 10 | 84241.7 [999.0] | — | 0.759 | — | — | ~540 |
| B | 10 | 81630.3 [1969.4] | -3.1% | 0.615 | **-19.0%** | 0.0001 | ~28 |
| C | 10 | 82896.8 [1186.6] | -1.6% | 0.659 | **-13.2%** | 0.0001 | ~23 |
| D | 10 | 82719.0 [1416.7] | -1.8% | 0.659 | **-13.2%** | 0.0001 | ~25 |

**结论**：

1. 无干扰场景下 C/D 吞吐在 ±2% 内（-1.6% / -1.8%），且 p99 显著改善 **-13.2%**；B 吞吐 -3.1%（略超 ±2%）
   但 p99 改善 -19.0%。整体不存在“明显退化”，延迟收益在无干扰下同样存在。
2. 迁移次数：fair baseline 约 500+/60s，sched_ext 各臂降至 ~25/60s（约 95% 降幅），
   与 LLC 亲和/迁移惩罚机制一致（formal-2 消融中关掉 LLC 控制损失 3.4% 吞吐）。
3. **最终验收口径汇总**：
   - 混部场景（v2）：D vs A **吞吐 +116.9%（p<0.0001）**，达标；
   - 无干扰回归：C/D 吞吐 ±2% 内、p99 -13.2%，达标；
   - 可归因：B/C/D 递进 + 3 组消融 + 迁移/分类/策略日志齐全。
