# SchedPilot 演示前风险清单与答辩 Q&A（实机校准版）

> ⚠️ **发布注意**：本文件写入了主机名、VM 名与仓库绝对路径（`rd350x`、`schedpilot-sp4`、`/root/schedpilot`）
> 以及二进制 SHA256。仓库上一个提交（`65c4485`）的 commit message 正是
> "sanitize environment-specific references (IPs, host names, absolute paths)"。
> **若这份文档要对外发布，请先确认脱敏口径。**

> 生成时间：2026-10-08。全部结论基于在演示机（`schedpilot-sp4`，openEuler 24.03 LTS-SP4 / `6.6.0-schedpilot`）
> 上的实机复跑，以及 `evidence/sp4-vm/` 归档数据与原始 `redis.out` 的重算。
> 配套文件：`docs/05_demo_runbook.md`（加固后的现场执行卡）。
>
> **说明**：本清单对团队已自行记录的事项**明确标注"已记录"**，不重复计为缺陷；只列"对外材料会翻车"的缺口。

---

## 一、按风险排序的发现

### S1 【已闭合】二进制溯源：头条数字来自更早的构建

> **2026-10-08 更新（本节结论已变化）**
>
> 原文标题写的是"证据链断裂"，**这个判断过重了**。事后在 HEAD `65c4485` 上做的干净重建证明：
> **构建是逐字节可复现的**，重建产物与现场二进制完全相同（`76f0cad3` / `68e57608`，
> 见 `evidence/sp4-vm/formal-5/rebuild-proof.txt`）。也就是说"现场二进制来路不明"并不成立——
> 它**就是 HEAD 源码树的产物**。
>
> 真正存在的、也是唯一存在的缺口是：**头条统计（+169.8%）来自更早的 v0.3.1 构建**。
> 该缺口已用 **formal-5**（同一套现场二进制、HEAD `65c4485`、A/D × 20 × 60s、**0 无效轮次**）补跑闭合：
> **QPS 中位 +183.8%、配对 +181.5% [+174.2, +188.8]，20/20 轮更高；p99 配对 −34.8%（20/20 更低）；
> p50 −86.9%（3.355→0.439ms）**；A 基线几乎不变（17274→17349），D 臂提升约 4.6%。
> 见 `evidence/sp4-vm/formal-5/`。**结论：不再是演示风险**；下面的原始分析保留作记录。

**事实**（逐项可在 `evidence/sp4-vm/*/experiment.meta.json` 核对）：

| 证据 | commit | loader sha256 | daemon sha256 | n | D vs A |
|---|---|---|---|---|---|
| `formal-4`（**头条 +169.8%**） | `be962b8` | `9d1e904f…` | `d02d4e0d…` | 20 | +169.8% |
| `mysql-3`（+85.2%） | `be962b8` | `9d1e904f…` | `d02d4e0d…` | 10 | +85.2% |
| `nginx-7`（+169.8%） | `3fdaf80` | `76f0cad3…` | `292016dd…` | 20 | +169.8% |
| `smoke-fixed` | `3fdaf80` | `76f0cad3…` | `68e57608…` | 3 | +201.0% |
| **现场机器实际** | HEAD `65c4485`（源码树） | **`76f0cad3…`** | **`68e57608…`** | — | 本次实测 +193.2%（n=1） |
| **formal-5（补跑）** | **`65c4485`** | **`76f0cad3…`** | **`68e57608…`** | **20** | **中位 +183.8% / 配对 +181.5% [174.2, 188.8]，20/20；p99 −34.8%** |

- 现场这对二进制（`76f0cad3`/`68e57608`）在全部归档里**只出现在 `smoke-fixed`（n=3、20 秒）**。
- **头条 +169.8% 用的 loader 是另一个哈希**（`9d1e904f`），不是现场这一个。
- 现场 HEAD 是 `65c4485`（v0.3.3），而 v0.3.3 明确改过数据面行为：**取消 `cache_slice` 自动收缩**、
  加 P1（CUSUM / NUMA 报告 / 动态 BG CPU pool）、intf fail-fast。头条矩阵是 v0.3.1（`be962b8`）跑的。

**团队已记录的部分**：`README.md` 后续规划表里有一条 P1："在 v0.3.3 最终构建上复跑 Redis/MySQL 正式矩阵（formal-5 / mysql-5）……（可选）"。

**缺口在于**：`docs/05_demo_runbook.md`（旧版）与 `submission/defense_pack.md` **完全没有提示这一点**，
PPT 提纲第 7 页直接写"Redis D +169.8%"、第 10 页写"证据链（commit+SHA256+原始归档）"——
只读这两份材料的答辩人会以为现场二进制就是产出该数字的二进制。**被问到时是最难补救的一类问题。**

**已执行的处置**：在 HEAD `65c4485` 上干净重建（证明可复现），并用该构建补跑
`bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 --arms A,D --results results/formal-5`，
归档 `evidence/sp4-vm/formal-5/`（含 `experiment.meta.json`、`per_run.csv`、`summary.md` 与原始 tar + sha256）。
这样"现场二进制 = 数字来源"成立。

> ⚠️ **重建时踩到的坑，值得记住**：`scripts/build.sh --install` **只把 loader 装到
> `/usr/local/bin/scx_schedpilot`，不更新 `$ROOT/build/scx_schedpilot`**；而
> `scripts/schedpilotctl.sh` 的 `loader_bin()` 优先使用 `build/` 下的副本。
> 所以按 README 执行 `--install` 重建后，**演示实际跑的仍是旧二进制**。
> 正确做法：不加 `--install`（该分支会 `cp` 到 `build/`），或重建后手动同步 `build/`。

---

### S2 【高】`d-no-llc` 消融在本 VM 上是**结构性空对照**

**事实**（实测 `cfg_before.json`，`flags` 位定义见 `bpf/intf.h`）：

| arm | flags | 含义 |
|---|---|---|
| D | **27** (`0x1b`) | 分类 DSQ + 预抢占 + BG 收容 + 自适应分类（**LLC 位 0x04 关**） |
| `d-no-llc` | **27** (`0x1b`) | **与 D 完全相同** |
| `d-no-bg` | **19** (`0x13`) | BG 收容位确实清掉了 → **有效消融** |

原因：daemon 检测到 LLC 拓扑退化后自动关闭 `llc_affinity`（`daemon/schedpilotd.cpp:794-809`），
日志有 `[WARN] degenerate LLC topology (16 domains / 16 cpus); disabling waker-LLC routing (single cache domain)`。
所以 `--ablation llc_affinity=0` **什么都没改变**，`d-no-llc` vs D 的任何差异都是噪声。

**团队已记录的部分**：`04_test_report.md` §6.11 第 420-421 行**明确写了**"该 VM 每 vCPU 独立 L3 域，
LLC 路由已被 daemon 自动关闭"；§6.9 第 3 条把它列为已修复缺陷（拓扑退化曾导致迁移风暴）。
**这是加分项，不是隐瞒。**

**缺口在于**：`04_test_report.md` §6.7 归因链、`formal-4/summary.md` 的 attribution chain、
`submission/defense_pack.md` 第 8 页**仍然把 `d-no-llc` 当作"3 组消融"之一**呈现。
评委只要问一句"你的 no-LLC 消融和 D 的 cfg flags 一样吗？"（现场 `--dump-cfg` 就能验），就会暴露。

**处置**：对外一律只说 **`d-no-bg`（有效）** 与 **`d-no-pmu`（见 S3 说明）**，
`d-no-llc` 改为"该 VM 上不构成有效对照（LLC 路由被自动关闭，flags 与 D 相同）"。
`04_test_report` §6.7/§6.10 的归因链加一行注脚。

---

### S3 【中高】`goodput@SLO(5ms)` 在冻结口径下等价于 QPS，不能当第二个指标讲

**事实**：A 的 p99 = 4.45ms **低于** 5ms 的 SLO，所以阈值对两边都不"咬"：
A 达标率 99.95%、D 99.997% → goodput ≈ QPS × 0.9995。
"QPS +169.8%" 与 "goodput +170.2%" 是**同一个事实的两种说法**，并列呈现等于重复计数。

**好消息（不用重跑就能修）**：`formal-4` 的原始 `redis.out` **仍在机器上**，我用归档数据重算了 SLO 敏感性（**基于 formal-4 旧构建**，两臂各 n=20，全部 20/20 轮更高）：

| SLO | A 达标率 | D 达标率 | goodput 配对均值 | 单轮区间 |
|---|---|---|---|---|
| 5.0ms | 99.95% | 100.00% | +170.2% | +141.5% ~ +192.0% |
| 4.5ms | 99.25% | 99.99% | +172.3% | +144.8% ~ +193.9% |
| **4.0ms** | **87.63%** | **99.99%** | **+207.7%** | +175.1% ~ +233.0% |
| 3.5ms | 50.26% | 99.90% | +436.4% | +377.6% ~ +482.1% |

**处置**：讲"SLO 敏感性"而不是单一阈值。这比单点数字**更抗质疑**（预先回答了"你是不是挑了个好看的 SLO"）。
4.0ms 处 A 掉 12.4% 请求、D 几乎不掉，是真正独立的第二个维度。
复算：`python3 bench/reparse_results.py results/formal-4 --slo-ms 4.0`（**会就地改写 summary.json，先备份**）。

---

### S4 【已修复】测试报告里"结论（正式）"用的是**冻结前**的 +116.9%

> ✅ **已修复（2026-10-08）**：`docs/04_test_report.md` 头部新增"口径分代"表，
> §1 摘要表与 §6.7 标题下均加了 supersede 横幅，明确 +116.9% 属冻结前、已被 §6.10 取代。

`04_test_report.md` §6.7 第 218 行标题为"**结论（正式，统计口径按配对复算修正）**"，
lead 的数字是 **+116.9%（配对 +116.78%）**——那是 `formal-2`（冻结前、`git_commit` 非最终提交、原始输出未入库）；
同一文档 §6.9 表格对 formal-2/mysql-2/nginx-2 打了 `*` 并注明是冻结前版本。
对外材料（README/PPT/defense_pack）全部是 **+169.8%**。

**风险**：评委翻到 §6.7 会看到两个互相矛盾的"正式结论"。
**处置**：在 §6.7 与 §6.9 标题下各加一行醒目 supersede 横幅，例如
"> ⚠️ 本节为冻结前（formal-2）口径，最终冻结口径见 §6.10：Redis D 配对 **+169.8% [+164.4, +175.2]，20/20**。"

---

### S5 【中】最强指标（中位延迟 7 倍）没用在对外材料里

**事实**（`formal-4` 20 轮）：p50 **A 3.375ms → D 0.467ms**，配对 −86.2%，
比值 **6.5×~7.8×（中位 7.2×）**，20/20 轮更优。p95 4.159→2.263ms。

**已记录部分**：`04_test_report.md` §6.7 第 227 行提过"p50 由 3.37ms 改善至 0.50ms（约 6.7×）"，但那是**冻结前**口径。

**缺口**：`README.md` 头条、`defense_pack.md` PPT 提纲、旧版 `docs/05` **都没用这个指标**，
反而把 `defense_pack` 的 Q&A 写成防守姿态（"p99 为什么不是大幅优化？"）。
**处置**：主动讲"尾延迟 −35%、**中位延迟 7 倍**（3.38ms→0.47ms）"，把防守题变成进攻题。
（旧版 `docs/05` 第 2 步只讲 p99，已在加固版补上。）

---

### S6 【中】现场单轮 Δ% 波动区间 +141% ~ +192%，不能报精确数字

两轮 30 秒实测：**+159.6%**（2026-10-05）与 **+193.2%**（2026-10-08）。
`formal-4` 60 秒的单轮配对区间 **+141.0% ~ +191.7%**。
波动几乎全来自 **A 臂**（16997~19467 QPS，±7%）；**D 臂很稳**（49832~50539，±0.7%）。
**处置**：标准话术见 `docs/05_demo_runbook.md` §2；被问时就引 20 轮冻结口径，**不要为了一轮数字重跑**。

---

### S7 【中】LLC / NUMA 拓扑退化：必须能解释，且它使 PPT 的一条设计卖点在演示机上不生效

- 演示机：16 vCPU、**单 NUMA 节点**、**LLC 拓扑退化（16 domains / 16 cpus）**。
- 后果 1：`llc_affinity` 自动关闭（见 S2）→ PPT 第 4 页"M-BOUND 长片 + **LLC 软亲和** + 迁移惩罚上限"
  在这台机器上**没有被执行**。
- 后果 2：JSONL 里的 `numa_local_pct: 100.0`、`numa_nodes: 1` 是退化的、无信息量（`04_test_report` §6.13 已注明"单节点 VM → 100%"）。
**处置**：主动说明"LLC/NUMA 是真实硬件上的能力，本演示 VM 是 KVM 客户机、每 vCPU 独立 cache 域，
daemon 按设计自动降级并打 WARN —— 这是 fail-safe，不是缺失"。**不要说"我们的 LLC 亲和提升了性能"。**

---

### S8 【低】现场可见但旧文档没写的输出 —— 已并入加固版 runbook

- `env_check.sh | tail -n 8` 实际会多出一行 `schedpilotd --status` 的 JSON（旧"期望输出"把它裁掉了）。
- 分类统计实际有 **4 类**，多出 `1 "class":"NORMAL"`（首帧：`reason: insufficient PMU/scheduling data`）。
- §4a 杀 loader 后 **`schedpilotd` 仍在运行**，§4b 的 `start` 会打印 `daemon already running` —— 正常现象。

### S9 【低】应急预案里 `pkill -f abcd_experiment` 会杀掉你自己的 SSH 会话

`pgrep -f` / `pkill -f` 的模式串出现在**调用者自己的 cmdline** 里时会自匹配。
本次校准两次踩中（`pgrep -f 'scx_schedpilot --mode'`、`pkill -f abcd_experiment`），两次都直接杀掉了 SSH 会话。
交互式逐行敲不受影响；但**用 `ssh host '整块命令'` 的方式推命令就会中招**——而这正是本项目的常见操作方式。
**处置**：统一改方括号写法 `pkill -f '[a]bcd_experiment'`，或读 pid 文件 `/run/schedpilot/*.pid`（已在加固版 runbook 改完）。

### S10 【已修复】`04_test_report` §6.12 措辞风险

> ✅ **已修复（2026-10-08）**：§6.12 已改为"**仅作跨内核可用性佐证，不并入 SP4 正式统计**"，
> 并修正了该节把 goodput 配对值 `+130.1%` 标成 QPS 的问题（QPS 配对为 `+128.98%`）。

SP3 迷你对照写的是"样本小，仅作跨内核可用性佐证，**并入正式统计**"。
n=2 × 20 秒的 SP3 数据被理解为"并进 20 轮冻结统计"会很难解释。
**处置**：改成"**作为独立的跨内核可用性佐证，不并入 SP4 正式统计**"。

---

## 二、答辩 Q&A（高频质疑 + 标准答案）

**Q1：为什么不用现成的 `scx_layered` / `scx_flatcg`？**
通用 DSL 需要人工写层规则，且规则是静态的；我们做的是场景内**自动分类 + 有界自适应**。
同一混部场景实测（`ext-2`，n=10）：`scx_simple` 吞吐 **−51.7%**、p99 **+351.9%**；
`scx_flatcg` **10/10 轮被内核 watchdog 卸载，0 个有效轮次**。通用示例调度器在该场景不可用。

**Q2：你现场跑的二进制，和 +169.8% 那个数字是同一个吗？**（原为最难的一题，现已闭合）
**直接答"是同一套"**，并给出证据链：正式冻结统计（+169.8%）来自 v0.3.1 构建（`be962b8`）；
现场是 v0.3.3 源码树构建（HEAD `65c4485`，`76f0cad3`/`68e57608`）。
**我们做了两件事**：① 在 HEAD 上干净重建，产物与现场二进制**逐字节相同**（证明构建可复现）；
② 用**现场这套二进制**补跑正式矩阵 **formal-5**（A/D × 20 × 60s，0 无效轮次），
得到 **配对 +181.5% [+174.2, +188.8]，20/20 轮更高**、p99 −34.8%、p50 −86.9%。
A 基线几乎不变（17274→17349），D 臂提升约 4.6%。
一句话："**现场这个二进制就是头条数字的来源**，而且我们验证过它可以从源码逐字节重建。"
（完整分析见 **S1**；证据 `evidence/sp4-vm/formal-5/`。）

**Q3：为什么 p99 只降 35%，不是数量级？**
主指标是吞吐/goodput；p99 受干扰片长底线约束（各臂 ~4.5ms 量级）。
但更有说服力的是另外两个数：**p50 3.375ms → 0.467ms（7.2 倍，20/20）**，p95 4.159 → 2.263ms。
即"中位和 95 分位大幅改善，p99 已逼近干扰片长决定的下限"。

**Q4：`goodput@SLO` 和 QPS 有什么区别？**
5ms 的 SLO 高于基线 p99，指标不"咬"，两者确实几乎等价——**如实承认**，
然后给 SLO 敏感性表（S3）：4.0ms 下 A 只有 87.6% 请求达标、D 有 99.99%，goodput 配对 **+207.7%**。
"我们把它当敏感性分析，而不是第二个独立指标。"

**Q5：消融为什么 CI 互相重叠？到底哪个机制有用？**
三组消融里 **`d-no-bg` 是有效对照**（flags 19 vs 27，BG 收容位真被清掉），效应 ≤2.2pp、CI 跨 0 → 如实标为趋势性；
**`d-no-llc` 在本 VM 上不构成有效对照**（LLC 路由被自动关闭，flags 与 D 相同，见 S2）；
`d-no-pmu` 的 cfg flags 不变（PMU 只影响分类器输入，不设 flag 位），且 Redis 靠调度特征已被判为 L-SYNC 置信度 1.0，
所以该消融在**本负载上**不改变分类结果。
**主收益来自 sched_ext 基础 + 三分类路由（B/C 两步，+66.7% 与再 +59.6%），这一层归因是稳健的。**

**Q6：你们支持 NUMA 吗？**
支持 **locality 报告**（`classifier.numa`，读 `/proc/<tgid>/numa_maps` + 当前 CPU → 节点，
输出 `numa_local_pct` / `numa_nodes`，report-only，**不参与决策**）。
本演示 VM 是单 NUMA 节点，所以字段恒为 100%/1，**无信息量**。
把它纳入 CACHE 路由决策是下一步（README 后续规划 P2）。

**Q7：用户态分类会不会太慢？**
决策周期 **100ms**（慢回路），快路径是 BPF 里 O(1) 查表 + generation/心跳校验，
分类只影响 DSQ 与切片参数，**任务不经过用户态转发**。
实测开销：`schedpilotd` **≈0.24–0.28 μs/请求**（≈1.3% 单核）、**0.082 次派发/请求**（`bench/measure_overhead.sh`）。
（原引用值 235 ns 的分母口径有误，见 S14。）
内核侧 BPF struct_ops 的 `run_time_ns` 本 6.6 backport 内核不暴露，**如实未折算**，以派发频次 + 0 watchdog 作上界。

**Q8：怎么保证没有"调数据"？**
全流程冻结：每次实验把 `git_commit` + 三个二进制 sha256 + 场景参数写进 `experiment.meta.json`；
`fail-fast` + 污染检测（`enable_seq` 变化即标 INVALID）；**负结果全部保留**
（formal-3 回归 +16.4%、`ext-2` flatcg 卸载 10/10、`nginx-5/6` D 臂因构建缺陷作废）。
**唯一的口径缺口是 S1（冻结后没重跑全量矩阵），我们如实标注。**

**Q9：什么是 fail-open？现场怎么证明？**
两层：loader 死 → sched_ext 自动 detach、默认 fair 接管（`dmesg` 有 `disabled (unregistered from user space)`）；
daemon 死 → BPF 保持在线并退回静态安全参数。
**硬证据用 `cfg_alive` / `cfg_stale`（BPF 每次派发决策递增），不要用 `flags`**，实测：

```
daemon 存活:  cfg_alive=846  → 1386（涨）   cfg_stale=220 → 220（冻结）
kill -9 daemon 后: cfg_alive=1630 → 1630（冻结）  cfg_stale=422 → 876（涨）   state=enabled
```

`cfg_alive` 停住 + `cfg_stale` 继续涨 + `state=enabled` = 数据面还在跑但已退回 `CLASS_DSQ|PREEMPT`（静态安全集）。
故障注入 6/6 PASS，15 分钟 soak 0 失速。

> ⚠️ **纠正**：本文档早先版本（以及 `docs/05` 的对应段落）曾用 `--status` 的 `flags` 15→27 作为 fail-open 证据，
> **那是错的**：`flags=15` 是 loader 启动时写入的默认值（`loader/scx_schedpilot.c`：`generation=1`、
> `flags=CLASS_DSQ|PREEMPT|LLC|BG_CONTAIN=15`），杀 daemon 后 `--status` 仍然打印 `flags=27`，
> 而 BPF **从不回写** `flags`。另外 `d-no-bg` 的 `flags=19 vs 27` 用于说明"消融确实改了配置"仍然成立。

**Q10：容器场景支持吗？**
支持 cgroup v2 子树目标选择（`configs/cgroup-demo.conf`，递归读 `cgroup.procs`，白名单校验），
回归测试 `tests/test_cgroup_targeting.sh` 5/5 PASS（SP4 与 SP3）。
深层容器 QoS/配额映射是下一步（P1）。

**Q11：为什么无干扰场景下吞吐反而降了？**
如实说明"以少量吞吐换尾延迟"的结构：`noif-2`（n=10）C/D 吞吐 **−3.2%~−3.3%（10/10 轮为负）**、
p99 **−11%~−12%**；B 吞吐 −5.7%、p99 −17.6%。
混部（本赛题场景）是吞吐大幅净收益；无干扰下是延迟收益换约 3% 吞吐。

**Q12：为什么基线叫"默认 fair"而不是"CFS"？**
赛题表述为默认 CFS；openEuler 的 6.6 内核里该调度类是 fair class，
**我们不把 Linux 6.6 fair-class 的内部实现等同于经典 CFS**，所以统一口径为
"openEuler 默认 fair-class 调度器（赛题表述：默认 CFS）"，避免过度声称。

---

## 三、演示前待办

> 已合并进 §五（含第二轮交叉审计新增的高优先级项），此处不再重复。

---

## 四、第二轮交叉审计补充（文档 ↔ 归档一致性）

第二轮是对全仓库文档与 `evidence/` 归档的逐条核对。下列条目**都能被评委用 `grep`/`cat` 现场验证**，
按"现场可被戳穿的程度"排序。已在前文覆盖的不重复。

### S11 【高】"收益是否靠饿死干扰任务换来？" —— 全程没有干扰侧数据

材料只报服务侧收益（Redis CPU 16.7%→49.9%，`04_test_report.md` §6.11），
**从未记录 BG（stress-ng）自身的完成量/进度/吞吐**。这是 +170% 最容易被质疑、也最难当场自证的一点。

可用的诚实的机制性回答：BG 是**有界降权而非饿死**——vtime 惩罚 ×2（`bg_vtime_pct=200`）、
切片收敛到 2ms（`bg_slice_ns`）、并且非 LAT 通道有 20ms 抗饥饿上限。
但**"有界"这句话目前没有测量支撑**。建议补测：同一场景下记录 stress-ng 单位时间的完成迭代数
（`stress-ng --metrics-brief` 已经会输出 bogo ops/s，实验脚本里现成可用），对比 A 臂与 D 臂各 5 轮。
这是**性价比最高的一项补测**。

### S12 【高】`configs/nginx.conf` 与 `deploy_nginx.sh` 的头部写着与结论相反的建议

> ✅ **本文档生成后已修复（2026-10-08）**：`configs/nginx.conf` 头部改为 `RECOMMENDED RUN MODE: adaptive`
> 并引用 nginx-7 的 C/D 配对数字；`deploy_nginx.sh` 头部更正了"C 被标成 classification + adaptive"的
> 错误标注、并把数字从 nginx-5 同步到 nginx-7。以下保留原始问题描述作为审计记录。

- `configs/nginx.conf` 头部至今写着：`# RECOMMENDED RUN MODE: basic`，并引 `§6.9` 的 `+43.8%`。
- `scripts/deploy_nginx.sh` 头部引的是 **nginx-5** 的数字，且把 `+127.4%` 标成
  `classification + adaptive (C)`——但 `+127.4%` 是 **C（静态分类）** 臂，D（自适应）只有 `+91.4%`。

而 `README.md`、`deploy_nginx.sh:9`、`nginx-7`（n=20）的结论是 **adaptive 推荐**
（C +167.8% / D +169.8%，p99 −69.6%，20/20）。**评委只要 `cat configs/nginx.conf` 就会拿到相反结论。**
处置：两处头部统一改为 adaptive 推荐 + nginx-7 的数字，basic 标注为保守回退。

### S13 【中】"0 无效轮次"这个标题下面有无效数据

`submission/evidence_index.md` 的章节标题写"冻结提交 be962b8，**0 无效轮次**"，其下却包含：
`ext-2`（**10/10 无效**，`invalid.log` 有 10 行）与 `nginx-5/6` 的 D 臂（被作废，
且仓库里**没有任何 invalid.log**，其 `summary.md` 仍显示 `D +99.40% … 20/20`）。
另外该节标题写 `be962b8`，但其中 `nginx-6` 的 meta 是 `0aa63b0`、`nginx-7` 是 `3fdaf80`。

**这是最危险的一条**：作废的 D 臂在归档里看起来干净且"有效"，容易被解读为挑选数据。
处置：标题改为"含已标注的无效臂"；给 nginx-5/6 补说明或补 `invalid.log`；
为 `nginx-7` 补上 commit + 三个二进制哈希（目前全网文档都没有它的溯源信息）。

### S14 【中】调度器开销 235 ns/请求的分母对不上

`evidence/sp4-vm/p1-evidence/overhead.log` 自身：`total=1076000 requests`、`45651 QPS`、
`schedpilotd CPU: 253.1 ms`、结论 `235.2`。
但 `1,076,000 / 45,651 = 23.6 s`，而 `perf stat` 只统计了 **20 s** 窗口
（`bench/measure_overhead.sh`：`perf stat … -- sleep 20`，而 `redis-benchmark -n` 跑到自然结束）。
按 20s 窗口内的实际请求数算，正确量级 ≈ `253.1 ms / 913k ≈ 277 ns`。
该数字被 README、CHANGELOG、`docs/04` §6.11、`docs/03`、本文档共 5 处引用。
处置：改为 **"≈0.25–0.28 μs/请求"** 并注明"两个测量窗口不完全对齐"；或让脚本按实测 QPS 估算 `-n`。

### S15 【已修复】`defense_pack.md` 第 1 页的算术错误

> ✅ **已修复（2026-10-08）**：封面已改为"吞吐提升至 **2.7 倍**（配对 +169.8%）、p99 降三成、
> 中位延迟降至 1/7"，并补上 p50 −86%。

`defense_pack.md` 写"把尾延迟敏感服务的吞吐提升 **1.7 倍**"，同页证据栏却写 `+169.8%`。
`+169.8%` 是 **×2.70**。封面页的低级算术错误，评委一眼可见。
（`docs/05` 已改用"2.4~2.9 倍"。）处置：改为"提升至 **2.7 倍**"。

### S16 【中】Nginx / MySQL 的基线是双峰的，文档从未披露

- `nginx-7`：A 臂 20 轮从 12095 到 21212，呈双峰（12.1–12.9k / 18.6–21.2k），**IQR 约为中位数的 35%**；
- `mysql-3`：A 臂 400.9 到 598.2，**IQR 同样约 35%**；
- 而 B/C/D 各臂的 IQR 只有 **1%–3%**。
- 对照 `04_test_report.md` §6.7 写"A 基线非常稳定（QPS IQR 仅 1.25k）"——**那只对 Redis 成立**。

评委必问"基线抖 35%、你的臂稳 2%，效应是不是来自基线抽到坏状态"。
配对统计能答（17–20/20 轮同向），但必须主动披露这个事实并给出 per-run 图。

### S17 【低】其他可 grep 到的不一致（建议一并修）

| 位置 | 问题 |
|---|---|
| `submission/defense_pack.md` 第 2 页 | "1.7 倍"（见 S15） |
| `README.md` 文档导航 | "测试方案（**场景 v2**…）"，而 `docs/02` 定义的是 **v3** |
| `docs/04_test_report.md` §6.7 | 标题为"**结论（正式）**"，lead 的却是**冻结前** formal-2 的 +116.9%；同节还有 `ext-1` 的 flatcg `+1.8%` 与 12 行后"flatcg 被卸载 10/10"（那是 ext-2）的混淆 |
| `docs/04_test_report.md` §6.7 修复表 | 把 anti-starvation 守卫列为"新增修复"，但 §6.10 又写"回退 anti-starvation 守卫"，前者未标已被推翻 |
| `docs/04_test_report.md` §6.12 | "样本小…**并入正式统计**"——n=2×20s 的 SP3 数据不应并入 SP4 的 20 轮统计（另：该节的 `+130.1%` 是 goodput 配对，QPS 配对是 `+128.98%`） |
| `docs/02_test_plan.md` | 要求"20 次有效重复"，最终 MySQL 矩阵是 n=10；组间仍写 Mann-Whitney，而报告已改为配对 CI |
| `docs/00_mvp_scope.md`、`SchedPilot_设计方案.md` | CUSUM / 动态 BG CPU pool 一处写"不做"，另一处写"已实现并测试通过"；设计方案还有"实现落地中""实验待跑"等过期表述 |
| `submission/evidence_index.md` | X-simple 写 −51.3%（配对），README/§6.9 写 −51.7%（中位），未标口径 |
| `VERSION` | 写 `0.3.0-mvp`，而 README 是 v0.3.1/v0.3.3；且**没有任何 git tag**，"冻结提交"无法 checkout |
| `evidence/sp4-vm/v033-sanity/` | **v0.3.3 唯一的 Redis/MySQL 复跑数字**（Redis +178%（n=3）、MySQL +55.6%（n=5）），却零引用；已补进 `README` 的口径边界说明。MySQL 该次 A 基线中位 561.3 TPS 与 `mysql-3` 的 479.3 相差 17%，D 却几乎不变（873.4 vs 880.8）→ 说明**基线漂移比效应更值得注意**，已如实披露 |
| `CHANGELOG.md` | 章节顺序是 v0.3.1 → v0.3.3 → v0.3.2；smoke 数字一处 `+190.1%`（smoke-cleanup）一处 `+201.0%`（smoke-fixed），而 `docs/04` 把两者分别判为"污染作废"和"被重跑替代"——等于没有有效 smoke |
| `tests/test_soak.sh` | 解析了 `--cycle` 参数但**全脚本未使用**，日志头恒写 `cycle=60s`，实际每周期约 18.4s（见 `soak-frozen.log` 的周期时间戳） |
| `docs/04_test_report.md` §6.11 | 该表 CPU 占用列（16.7/26.8/48.2/49.9%）**无法从归档复核**：`formal-4/per_run.csv` 没有 CPU% 列，来源 `perf_stat.txt` 未归档。这是 PPT 上最常引用的数字，建议把 task-clock 汇总进 summary.csv |
| ~~`configs/nginx.conf`、`deploy_nginx.sh`~~ | ✅ **已修复**（见 S12 顶部说明） |

> **审计口径声明**：本节所有数字均已回到 `evidence/sp4-vm/*/experiment.meta.json`、`summary.md`、
> `per_run.csv`、`invalid.log` 原始归档核对；原始 `redis.out` 仍在实验机上，
> 因此 SLO 类重算无需重跑实验。

---

## 五、演示前待办（按性价比排序）

| # | 事项 | 状态 |
|---|---|---|
| 1 | **背下 S2/S11/Q2/Q4/Q5 的答案**（并写进 PPT 备注页）——S1 已闭合，不必再背 | 待做（40 分钟） |
| 2 | ~~改 `configs/nginx.conf` + `deploy_nginx.sh` 头部~~（S12） | ✅ 已完成 |
| 3 | ~~重建 + 补跑 `formal-5`~~（S1）✅ **已完成**：重建证明构建逐字节可复现；formal-5 = **中位 +183.8% / 配对 +181.5%（20/20）**，0 无效轮次，归档 `evidence/sp4-vm/formal-5/` | ✅ 已完成 |
| 4 | **补测干扰侧完成量**（S11，`stress-ng --metrics-brief` 现成）——**当前性价比最高的一项** | 待做（30 分钟） |
| 5 | ~~`04_test_report` §1/§6.7 加 supersede 横幅；§6.12 改"不并入"~~（S4/S10） | ✅ 已完成 |
| 6 | ~~`defense_pack` 改"2.7 倍"~~（S15） | ✅ 已完成 |
| 7 | **SLO 敏感性表进 PPT**（S3） | 待做（10 分钟） |
| 8 | **`evidence_index` 标题已改；`nginx-7` 补 commit + 三哈希**（S13） | 部分完成（补哈希待做） |
| 9 | ~~在 §4b 用 `cfg_alive`/`cfg_stale` 替换 flags 论证~~ | ✅ 已完成 |
| 10 | **`official`：VERSION / 统计口径 / P1 状态 / 设计方案过期表述**（S17） | ✅ 已完成 |
| 11 | **PPT 第 4 页"LLC 软亲和"卖点**：本 VM 上自动关闭，需按 S7 的说法讲 | 待做（5 分钟） |
| 12 | **PPT 第 6 页回归故事**：`pilot-6..9` 数字无归档，建议只用 formal-3→formal-4 两个有归档的端点 | 待做（10 分钟） |
| 13 | ~~项目说明书无图~~：已补 **7 张图**（总体架构 / 数据面三队列 / 控制面闭环 / 双层 fail-open / 实验场景 / QPS / 延迟），并新增"核心结果速览"页 | ✅ 已完成 |

---

## 六、本次校准的复核记录（可复现）

```
# 环境
eth0/gateway→ ssh schedpilot-sp4 → openEuler 24.03 LTS-SP4, 6.6.0-schedpilot, 16 vCPU, 1 NUMA node
/root/schedpilot @ 65c4485, working tree clean
build/scx_schedpilot sha256 = 76f0cad31ee56018f08fbd5d1fc0065500d72b2c0c0ced286720978eb89a9ccb
build/schedpilotd    sha256 = 68e57608fa493a91aff4587afe4dd21035889e82a8f4f86a1e11acdebb55b05d

# 逐条实测
env_check.sh | tail -n 8                       → OK=34 WARN=1 FAIL=0
schedpilotctl.sh start --mode adaptive ...     → state=enabled ops=schedpilot
demo.sh 30 1                                   → 97s; A 16997.53 → D 49832.43 (+193.2%), p99 4.399→2.879ms, p50 3.367→0.431ms
分类日志 uniq -c                                  → BG 3771 / L-SYNC 383 / M-BOUND 65 / NORMAL 1
kill -9 <loader.pid>                           → /sys/kernel/sched_ext/state = disabled
kill -9 <daemon.pid>                           → state = enabled（fail-open 保持）
  fail-open 计数（正确证据）：
    daemon 存活  cfg_alive=846→1386（涨）   cfg_stale=220→220（冻结）
    kill daemon 后 cfg_alive=1630→1630（冻结） cfg_stale=422→876（涨）
  注：此时 `schedpilotd --status` 仍打印 flags=27 —— 所以 flags 不能证明降级
schedpilotctl.sh rollback                      → state = disabled
dmesg | grep -a sched_ext | tail -3            → 3 行均为正常 enable/disable，无 watchdog/stall

# flags 位（bpf/intf.h）—— 仅表示"pin 上的原始 cfg 值"，不是 fail-open 证据
0x01 分类DSQ  0x02 预抢占  0x04 LLC软亲和  0x08 BG收容  0x10 自适应分类
formal-4: A=11  B=15  C=11  D=27  d-no-pmu=27  d-no-llc=27  d-no-bg=19
  说明：15 = loader 启动默认值（generation=1）；27 = daemon 写入（置 CLASSIFY、清 LLC）；
  d-no-llc ≡ D（均为 27）⇒ 该消融是结构性空对照；d-no-bg=19 ⇒ BG 收容位确被清除，是有效消融

# 原始数据重算（未重跑）
SP_SLO_MS=4.0 parse_redis.py × formal-4 40 个 run → goodput 配对 +207.7%（20/20 更高）
```
