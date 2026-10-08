# SchedPilot 10 分钟演示流程（评审现场版 · 实机校准）

> ⚠️ **发布注意**：本文件为了"能照着跑通"写入了主机名、VM 名与仓库绝对路径
> （`rd350x`、`schedpilot-sp4`、`/root/schedpilot`）。仓库上一个提交（`65c4485`）的
> commit message 正是"sanitize environment-specific references (IPs, host names, absolute paths)"。
> **若这份文档要对外发布，请先确认脱敏口径**；内部使用可直接保留。

> **校准说明**：本文档每条命令与"实际输出"均在 **2026-10-08** 于演示机实机逐条复跑校准。
> 凡是与旧版不同的地方，都在原地标注了 `【校准】`。文末有"本次校准改了什么"清单。
>
> **讲解主口径**：同 CPU 干扰混部下，SchedPilot 全自适应（D）相对 openEuler 默认 fair（A）**QPS +180% 量级**。
> 正式 20 轮统计口径（**最终构建 `formal-5`，commit `65c4485`，与现场二进制同一套**）：
> QPS 中位 +183.8%、**配对 +181.5% [174.2, 188.8]，20/20 轮更高**；p99 −34.8%；**中位延迟 −86.9%（3.36ms→0.44ms，约 7.6 倍）**。
> 前代冻结矩阵（`formal-4`，`be962b8`）为配对 +169.8%，两代一致。
> 现场用 1 轮快速对比展示趋势，**不要现场报精确数字**（见 §2）。

---

## 准备篇：环境事实、清场检查与时间轴（先读，此篇不占演示时间，编号不是步骤号）

| 项 | 事实 |
|---|---|
| 演示机 | **rd350x 宿主机上的 KVM 客户机 `schedpilot-sp4`**（不是宿主机本身） |
| 登录方式 | `ssh schedpilot-sp4` → root，落在客户机 |
| 客户机 OS | **openEuler 24.03 LTS-SP4** |
| 内核 | **`6.6.0-schedpilot`**（自编译、启用 `CONFIG_SCHED_CLASS_EXT`） |
| 拓扑 | 16 vCPU / **单 NUMA 节点** / LLC 拓扑退化（`16 domains / 16 cpus`） |
| 仓库 | `/root/schedpilot`，HEAD **`65c4485`**，构建产物已就绪 |
| 二进制 | `build/scx_schedpilot` = `76f0cad3…`；`build/schedpilotd` = `68e57608…` |

> **关于 `git status`**：演示机上会看到 `M docs/05_demo_runbook.md` 和 `?? docs/06_demo_risks_qa.md`
> 等**文档类**改动——这是本次校准同步过去的材料，属于正常。**只要 `git log --oneline -1` 是 `65c4485`
> 且源码目录（`bpf/`、`loader/`、`daemon/`）没有改动，构建与数据就是可信的。**
> 若想让树完全干净，可在演示前 `git stash -u`（会把这两份文档一起收走，介意就别做）。

> ⚠️ **不要在 rd350x 宿主机上跑演示。** 宿主是 Ubuntu 24.04.1 LTS + 内核 `6.8.0-51-generic`，
> **没有 sched_ext**（`/sys/kernel/sched_ext` 不存在），且仓库不在宿主上（`~/schedpilot` 已不存在）。
> 宿主只负责把 VM 跑起来。

### 上台前 5 分钟检查（清场）

```bash
# ① 在你自己的电脑上：确认 VM 处于 running
ssh rd350x 'virsh -c qemu:///system list --all | grep schedpilot-sp4'
# 期望： 12   schedpilot-sp4    running

# ② 进客户机：清场 + 确认前提
ssh schedpilot-sp4
cd /root/schedpilot
scripts/schedpilotctl.sh rollback      # 回到默认 fair
bench/interference.sh stop             # 清干扰
cat /sys/kernel/sched_ext/state        # 期望： disabled
git log --oneline -1                   # 期望： 65c4485 …
ls -l build/scx_schedpilot build/schedpilotd
```

> **残留说明**：机器上长期有一个 `redis-server 127.0.0.1:6399`（实验脚本会"收养"它并重新绑核，
> 不会导致端口冲突，**不必手动清**）。真正会碍事的是残留的
> `abcd_experiment` / `stress-ng` / `scx_schedpilot`，清场命令已覆盖。

### ⚠️ 如果你用 SSH 一条一条推命令（而不是在终端里逐行敲）

**`pgrep -f` / `pkill -f` 会匹配到你自己那条 SSH 命令串，从而杀掉你自己的会话。**
本次校准就踩了两次（§4a 的 `pgrep -f 'scx_schedpilot --mode'`、应急预案的 `pkill -f abcd_experiment`）。

- **安全的写法**：用方括号打断自匹配 —— `pgrep -f '[s]cx_schedpilot --mode'`、`pkill -f '[a]bcd_experiment'`
- **更稳的写法**：直接用 pid 文件 —— `cat /run/schedpilot/scx_schedpilot.pid`
- 在**交互式终端里逐行敲**（或把整段存成 `.sh` 再 `bash x.sh`）**不受影响**，因为 shell 自己的 cmdline 不含该模式串。

---

## 时间轴（实测）

| 段 | 命令耗时（实测） | 内容 |
|---|---|---|
| **开场口播** | **0s（不跑命令）** | **先讲清"我们在做什么"**：混部痛点 → 我们的做法 → 做成了什么（见下一节，约 60–90 秒） |
| 0 环境自检 | ~5s | `env_check`：全绿 OK=34 WARN=1 FAIL=0 |
| 1 一条命令上线 | ~10s | 加载调度器 + 状态 + 数据面统计 |
| 2 优势实验 | **97s** | `demo.sh 30 1`：A（默认 fair）vs D（SchedPilot） |
| 3 分类实况 | ~2s | 从 JSONL 日志看 L-SYNC / BG / M-BOUND 实时分类 |
| 4 安全兜底 | ~25s | 杀 loader → 回默认 fair；杀 daemon → 调度器保持在线 |
| 5 收尾 | ~5s | rollback + dmesg 无 watchdog/stall |
| — | **命令合计约 2.5 分钟** | 开场 1.5 分钟 + 命令 2.5 分钟 + 各步讲解，控制在 10 分钟以内 |

---

## 开场口播（约 60–90 秒 · 不跑命令 · 先把"我们在做什么"讲清楚）

> 建议在切到终端**之前**讲完，配 PPT 第 1–2 页。
> **必讲**：①③⑤ + 过渡（约 60 秒）。**有时间再展开**：②④（各约 15 秒）。只剩 5 分钟时，只讲 ①③⑤。

**① 我们做的是什么（一句话）**
> 我们做了一个**能"看懂"负载的 Linux 调度器**：它先判断每个程序是什么类型，再把 CPU 优先给"有人在等"的服务，
> 让"可以慢慢来"的后台任务排队。项目叫 SchedPilot。

**② 为什么需要它**（可选展开）
> 云原生为了省机器，会把很多程序挤在同一批 CPU 上跑，这叫"混部"。默认调度器对所有程序一视同仁——
> 它不知道哪个是用户正在等的在线服务，哪个是可以缓一缓的干扰任务。

**③ 不解决会怎样（我们实测到的痛）**
> 让 Redis 和几个压测程序抢同一批 CPU：默认调度器只让 Redis 拿到**约 17% 的 CPU 时间**，
> 而且**一次都不给它换核**——就把它按在原地饿着。用户感受到的就是"卡"。

**④ 我们怎么做的**（可选展开）
> 利用 Linux 6.6 的 **sched_ext** 机制（内核官方给的"调度策略可编程"接口），我们搭了一个闭环：
> ① 用 **eBPF** 在内核里观察每个程序怎么跑（唤醒频率、运行时长、IPC、缓存缺失）；
> ② 用户态程序**每 100 毫秒**判断一次它是"延迟敏感 / 计算型 / 内存型 / 后台干扰"；
> ③ 把判断结果下发回内核的调度器，该优先的优先、该降权的降权。
> 一句话概括设计：**判断放在用户态（慢，但可解释、可审计）；执行放在内核里（快，且任务不经过用户态转发）。**

**⑤ 做成了什么**
> 同一台机器、同一个负载、同样的干扰，**唯一变量是调度器**：
> Redis 吞吐 **1.7 万 → 4.9 万 QPS（2.8 倍）**，尾延迟 **−35%**，
> **中位延迟 3.36 毫秒 → 0.44 毫秒（约 7.6 倍）**；**20 轮重复，20 轮全部更好**。

**⑥ 过渡到演示**
> 下面我按顺序把关键环节实际跑一遍：先确认环境，再一条命令上线，然后做 A/B 对比，看分类日志，
> 最后演示"万一出问题会不会失控"。

---

## 0. 环境自检（约 5 秒）

```bash
cd /root/schedpilot
scripts/env_check.sh | tail -n 8
```

实际输出（**校准**：比旧版多一行 `schedpilotd --status` 的 JSON，旧版"期望输出"把它裁掉了）：

```
[OK] workload.sysbench            /usr/bin/sysbench
[OK] workload.stress-ng           /usr/bin/stress-ng
[OK] schedpilot.loader            /root/schedpilot/build/scx_schedpilot
[OK] schedpilot.daemon            /root/schedpilot/build/schedpilotd
[OK] schedpilot.pinned_maps       cfg class_map cpu_llc stats tg_stats
{"mode":2,"generation":3,"flags":27,"heartbeat_age_s":0,"class_map_entries":1,"pmu_available":true,...}

=== summary: OK=34 WARN=1 FAIL=0 ===
```

**讲解词**

- **做什么**：一条命令探测这台机器具不具备条件——内核有没有开 `sched_ext`、工具链全不全、压测工具在不在。
- **说明什么**：**0 个 FAIL**，说明实验环境干净、可复现；后面所有数字都在这个环境里产生。
- **我们的优势**：**不改发行版、不打私有补丁**，只多打开一个内核官方开关（`CONFIG_SCHED_CLASS_EXT`）重建内核即可。
  正因如此，我们才能在 **openEuler SP4 与 SP3 两个版本上都跑起来**（SP3 是自编译内核、仓库代码零改动通过）。
- **可以这样说**：
  > "这是我们实验前的环境自检，34 项通过、0 项失败。我们的方案不依赖私有补丁，只打开内核官方的一个开关，
  > 所以在 SP4 和 SP3 上都能跑。"
- 附带说明：那行 `[WARN] memtier_benchmark 未安装`是正常的，我们统一用 `redis-benchmark` 压测，口径一致。

> **【校准】清场后第一次跑这行要注意**：如果上一步没 rollback，`heartbeat_age_s` 可能是几十小时前的残留值。
> 先执行准备篇里的 `rollback` 即可让它归零。别让评委看到一个"心跳停了 42 小时"的数字。

---

## 1. 一条命令上线（约 10 秒）

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
scripts/schedpilotctl.sh status
build/scx_schedpilot --stats | head -n 3
```

实际输出（三条命令的输出分开标注，**不要当成一段**）：

```
① schedpilotctl.sh start  →
[schedpilot] starting scx_schedpilot --mode adaptive
[schedpilot] sched_ext state=enabled ops=schedpilot
[schedpilot] starting schedpilotd --config configs/redis.conf
[schedpilot] started (mode=adaptive)

② schedpilotctl.sh status  →
loader_pid=308266 daemon_pid=308279
sched_ext.state=enabled
sched_ext.ops=schedpilot
sched_ext.state=enabled
sched_ext.enable_seq=1294
cfg mode=2 generation=2 flags=0x1b hb_seq=6 hb_mono_s=671737 lat_slice=1000000 comp_slice=4000000 cache_slice=8000000 bg_slice=2000000 preempt_thr=500000 migrate_pen=2000000 bg_vtime_pct=200
{"mode":2,"generation":2,"flags":27,"heartbeat_age_s":0,"class_map_entries":1,"pmu_available":true,...}

③ build/scx_schedpilot --stats | head -n 3  →
sched_ext.state=enabled
sched_ext.enable_seq=1294
cfg mode=2 generation=2 flags=0x1b hb_seq=6 hb_mono_s=671737 lat_slice=1000000 …
```

> **【校准】`--stats` 的两个坑**（`loader/scx_schedpilot.c`）：
> 1. 它的输出顺序是 **state → enable_seq → cfg → 计数器**，`head -n 3` 拿到的是前三条，**第四行才是计数器**；
> 2. 它**会跳过所有值为 0 的计数器**。所以刚 `start` 的一瞬间计数器行可能是空行/不存在，
>    要等跑起来几秒才有内容。**想稳，改用 `schedpilotctl.sh status` 里那段 JSON（恒有内容）。**
>
> 讲"数据面统计"时建议先跑 §2 的实验，或至少等 5 秒再看 `--stats`。

**讲解词**

- **做什么**：一条命令，把**内核里的调度器**和**用户态的判断程序**一起拉起来。
- **说明什么**：`state=enabled` 表示调度器**已经真正接管**这台机器的调度——这不是 PPT，是正在运行的系统；
  下面还能看到配置文件已经写进内核（`cfg mode=2 generation=2 flags=0x1b`）。
- **我们的优势（也是设计上最关键的一点）**：**判断放在用户态（每 100ms 一次），执行放在内核里**。
  所以它① 可解释、可审计，② 任务不需要转发到用户态，单次调度开销极低（每请求约 0.24–0.28 微秒量级），
  ③ 带心跳校验——用户态程序一旦死掉，内核自动退回静态安全参数。
- **可以这样说**：
  > "一条命令上线。state=enabled 说明调度器已经接管。请注意我们的分工：判断在用户态、每 100 毫秒一次；
  > 执行在内核里。这样它既说得清为什么这么调，又不会拖慢每一次调度。"
- 技术细节（被追问时再展开）：数据面是三条队列——延迟敏感走"短时间片 + 优先派发 + 唤醒抢占"，
  计算型走公平排队，内存型走长时间片 + 缓存亲和；控制面用的是"唤醒率、运行时长、等待时间、上下文切换 +
  硬件计数器（IPC、缓存缺失）"，做平滑和滞回判断，只允许在有界范围内微调。

> **【校准】关于 `flags=0x1b`（=27）**：这次现场可以主动讲，是个加分点。
> 位定义（`bpf/intf.h`）：`0x01` 分类 DSQ、`0x02` 唤醒预抢占、`0x04` LLC 软亲和、`0x08` BG 收容、`0x10` 自适应分类。
> 所以 `0x1b` = 分类 DSQ + 预抢占 + BG 收容 + 自适应分类，**LLC 软亲和位是关的**——因为本 VM 的
> LLC 拓扑退化（每个 vCPU 各自暴露一个 cache 域），daemon 启动时**自动关闭** waker-LLC 路由并打 WARN：
> `[WARN] degenerate LLC topology (16 domains / 16 cpus); disabling waker-LLC routing (single cache domain)`
> 这是**主动的降级保护**，不是没实现。见 §7 与 `docs/06_demo_risks_qa.md`。
>
> ⚠️ 但请**只把它当作"当前生效配置"的展示**，不要延伸成"fail-open 的证据"——那个用法是错的，见 §4b 的警告框。

---

## 2. 优势实验：干扰混部 A vs D（约 97 秒）

```bash
scripts/demo.sh 30 1
```

`demo.sh` 自动完成：自检 → 回滚 → 启动 Redis + stress-ng CPU/内存干扰（服务与干扰同 CPU 0-3，客户端隔离 4-7）
→ A 轮（默认 fair）→ D 轮（SchedPilot 全自适应）→ 汇总 → 回滚。**耗时实测 97 秒**（旧文档写 ~100s，准确）。

查看结果：

```bash
sed -n '1,16p' $(ls -td results/demo-* | head -n1)/summary.md
```

**本次实测结果（2026-10-08，30s×1 轮）**：

| arm | n | QPS | QPS Δ | p50 (ms) | p99 (ms) | p99 Δ |
|---|---|---|---|---|---|---|
| A（默认 fair） | 1 | 16997.53 | +0.0% | 3.367 | 4.399 | +0.0% |
| **D（SchedPilot）** | 1 | **49832.43** | **+193.2%** | **0.431** | **2.879** | **−34.6%** |

旧文档记录的另一轮（2026-10-05）：A 19466.77 → D 50538.61，**+159.6%**，p99 −34.7%。

> **【校准】现场千万不要报精确数字。** 两轮 30s 实测的 Δ% 分别是 **+159.6%** 和 **+193.2%**；
> 正式 20 轮 60s 的单轮配对区间是 **+141.0% ~ +191.7%**。
> 波动几乎全部来自 **A 臂**（16997~19467，±7%），**D 臂非常稳**（49832~50539，±0.7%）。
>
> **标准话术**："A→D 吞吐大约 2.4 到 2.9 倍；正式 20 轮统计是配对 +169.8%，20/20 轮全部更高。"
> 如果现场 A 恰好跑高了，说"这轮基线偏高，以 20 轮冻结口径为准"，然后继续——不要重跑，浪费时间。
>
> **【校准】还有一个结构性问题要知道**：`demo.sh` 传的是 `--runs 1`，而臂轮转 offset=(run-1)%N，
> 所以**单轮演示里 A 永远先跑、D 永远后跑**，没有交织去偏，n=1 也没有置信区间。
> 被问到就答："单轮只是趋势示意；顺序固定带来的热漂移我们用正式矩阵的逐轮轮转交织消除了。"
> 另外：`demo.sh` 内部用的是 `env_check | tail -n 6`，所以现场那一段自检只显示 6 行，属正常。

**讲解词**

- **做什么**：在**完全相同的条件**下跑两轮——第一轮用系统默认调度器（A），第二轮换成我们的（D）。
  同一台机器、同一个 Redis、同样的 CPU/内存干扰，**唯一变量就是调度器**。
- **说明什么**：因为是唯一变量，两轮的差距只能归因于调度算法本身。屏幕上还能同时看到"为什么会有差距"：
  默认调度器只让 Redis 拿到 **约 17% 的 CPU 时间**，而且 `cpu-migrations = 0`——**它一次都不给 Redis 换核，
  就把它按在原地饿着**；换成我们的调度器后 Redis 拿到 **52%**。
- **解决了什么问题**：在线服务被干扰任务"公平地"饿死的问题。
- **我们的优势**：我们**不是把干扰任务杀掉**，而是**分级**——后台任务仍然拿得到 CPU
  （设了 20 毫秒的抗饥饿下限，不会被饿死），只是排在在线服务后面。
  这就是"该快的快、该让的让"。结果是**吞吐和尾延迟同时变好**，而不是牺牲一个换另一个。
- **可以这样说**：
  > "这是唯一变量实验：同样的机器、同样的负载、同样的干扰，只换调度器。默认调度器只给 Redis 约 17% 的 CPU，
  > 而且从不给它换核；我们给到 52%。吞吐从 1.7 万到 4.9 万，中位延迟从 3.4 毫秒降到 0.44 毫秒。
  > 注意我们并没有饿死那些干扰任务——它们照样拿得到 CPU，只是排在在线服务后面。"
- 正式口径（被追问时再说）：正式矩阵 20 轮 × 60 秒，**20 轮全部更好**，QPS 配对 **+181.5%**（95% CI [+174.2%, +188.8]）。

---

## 3. 分类实况（约 2 秒，可插在实验后）

```bash
RUN=$(ls -td results/demo-* | head -n1)
LOG=$(ls $RUN/D/run-01/logs/schedpilotd-*.jsonl | head -n1)
grep -m 2 '"class":"L-SYNC"' "$LOG" | cut -c1-220
grep -m 2 '"class":"BG"'     "$LOG" | cut -c1-220
grep -o '"class":"[A-Z-]*"'  "$LOG" | sort | uniq -c
```

实际输出：

```
{"type":"sample",...,"comm":"redis-server","class":"L-SYNC","confidence":1.000,"changed":true,...,"features":{"sched_valid":true,"pmu_valid":true,...
{"type":"sample",...,"comm":"stress-ng","class":"BG","confidence":1.0,"source":"external","bg":true,"numa_local_pct":100.000000,"numa_nodes":1}
   3771 "class":"BG"
    383 "class":"L-SYNC"
     65 "class":"M-BOUND"
      1 "class":"NORMAL"
```

> **【校准】实际会多出两样旧文档没写的东西**，评委看得见，要能解释：
>
> 1. **`1 "class":"NORMAL"`**（旧文档只列了 3 类）。这是**首帧**：特征还没就绪，
>    `{"class":"NORMAL","confidence":0.300,...,"reason":"insufficient PMU/scheduling data"}`。
>    一句话解释："daemon 起来后第一帧调度/PMU 数据还没攒够，落在保守的 NORMAL，第二帧就进 L-SYNC 了。"
> 2. **`numa_local_pct: 100.0, numa_nodes: 1`**（P1 新增的 NUMA 观测）。本 VM 是**单 NUMA 节点**，
>    这两个字段因此是退化的、无信息量。评委若问 NUMA，见 `docs/06_demo_risks_qa.md` §Q6。

**讲解词**

- **做什么**：把刚才那一轮里**每一次分类判断的日志**翻出来看。
- **说明什么**：证明"分类"是**真实发生、而且可审计**的，不是事后编的说法——
  `redis-server` 因为高频唤醒 + 高 IPC 被判成延迟敏感（L-SYNC）；`stress-ng` 是我们在配置里**显式标记**的后台任务。
- **我们的优势**：每一次判断都记录了**特征、置信度和变更原因**，可以逐条对质。
  这是一个**可解释、可追责**的调度器，而不是"黑盒调参"。
- **可以这样说**：
  > "刚才那些判断不是黑盒。每一次决策都落成了日志：Redis 因为高频唤醒和高 IPC 被判成延迟敏感；
  > stress-ng 是我们在配置里显式标记的后台任务，不是靠猜的。欢迎老师们逐条检查。"
- 小提示：统计里会出现 `1 "class":"NORMAL"`，那是**第一帧**——特征还没攒够，先落在保守值，第二帧就进入正常分类。

---

## 4. 安全兜底演示（约 25 秒）

**4a. 杀 loader → 内核自动回默认 fair：**

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
L=$(cat /run/schedpilot/scx_schedpilot.pid); echo "loader=$L"   # 【校准】改用 pid 文件，避免 pgrep 自匹配
kill -9 "$L"; sleep 2
cat /sys/kernel/sched_ext/state          # 期望: disabled
scripts/schedpilotctl.sh daemon-stop     # 【校准】必须补这一步，理由见下
```

实际输出：

```
[schedpilot] starting scx_schedpilot --mode adaptive
[schedpilot] sched_ext state=enabled ops=schedpilot
[schedpilot] starting schedpilotd --config configs/redis.conf
[schedpilot] started (mode=adaptive)
loader=309598
disabled
```

**4b. 杀 daemon → 数据面 fail-open 保持在线：**

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
D=$(cat /run/schedpilot/schedpilotd.pid); kill -9 "$D"; sleep 4
cat /sys/kernel/sched_ext/state                     # 期望: enabled
build/scx_schedpilot --stats | grep -o 'cfg_alive=[0-9]* cfg_stale=[0-9]*'
sleep 5
build/scx_schedpilot --stats | grep -o 'cfg_alive=[0-9]* cfg_stale=[0-9]'
```

**实测输出（这才是 fail-open 的硬证据）**：

```
T0 (daemon 存活):  cfg_alive=846  cfg_stale=220
T1 (+4s, 存活):    cfg_alive=1386 cfg_stale=220     ← cfg_alive 增长、cfg_stale 冻结
-- kill -9 daemon, 等 4s --
T2 (post-kill):    cfg_alive=1630 cfg_stale=422
T3 (+5s):          cfg_alive=1630 cfg_stale=876     ← cfg_alive 冻结、cfg_stale 增长
state=enabled
```

**讲解词**

- **做什么**：**故意把我们自己的两个用户态程序杀掉**，看内核会怎样。
- **说明什么**：证明最坏情况下系统**不会失控**——
  杀掉 loader → 内核**自动摘掉**我们的调度器、回到系统默认调度器（业务不中断）；
  杀掉判断程序 → 调度器**留在内核里**，退回一套静态安全参数继续工作。
- **解决了什么问题**：调度器运行在内核最敏感的位置，"会不会把系统搞挂"是最大的顾虑。
- **我们的优势**：**双层兜底 + 一键回滚**，所以它敢拿到生产环境去试。
  故障注入测试 **6 轮全部通过**，15 分钟长稳 0 次失速。
- **可以这样说**：
  > "调度器在内核里，所以必须能安全退出。我们杀掉 loader，内核立刻自动换回默认调度器，业务不中断；
  > 我们杀掉判断程序，调度器还留在内核里，用一套静态安全参数继续跑。下面这两个计数器可以证明它确实降级了。"
- 现场证明"真的降级了"：daemon 活着时 `cfg_alive` 在涨、`cfg_stale` 不动；杀掉 daemon 后 `cfg_alive` **冻住**、
  `cfg_stale` 开始涨——说明调度器还在跑，但已经换成了静态安全参数。

**怎么现场证明"真的降级了"**——看上面四个数：daemon 活着时 `cfg_alive` 在涨而 `cfg_stale` 不动；
杀掉 daemon 后 `cfg_alive` **冻住**而 `cfg_stale` 开始涨。
这两个计数器由 BPF 在**每次派发决策**时递增（`bpf/scx_schedpilot.bpf.c` 的 `effective_flags()`）：
心跳过期就记 `cfg_stale` 并只返回 `CLASS_DSQ|PREEMPT`（静态安全集），心跳正常才记 `cfg_alive`。
所以"`cfg_alive` 停住 + `cfg_stale` 继续涨 + `state=enabled`"就是"数据面还在跑、但已退回静态参数"的直接证据。

> **⚠️【校准】不要用 `--status` 里的 `flags` 来证明 fail-open——我一开始就是这么写的，是错的。**
> `flags` 只是 pinned map 里的**原始值**，反映"这套 pin 上有没有 daemon 写过"，与 BPF 的降级无关。
> 实测反证：杀掉 daemon 之后 `build/schedpilotd --status` **仍然打印 `"flags":27`**（daemon 死前写进去的值），
> 而 BPF 实际生效的是 `CLASS_DSQ|PREEMPT = 3`。另外 BPF **从不回写** `flags`。
> 顺带：`generation`/`flags` 在 rollback 后可能显示 1/15，那是 **loader 启动时的默认值**
> （`loader/scx_schedpilot.c`：`generation=1`、`flags=CLASS_DSQ|PREEMPT|LLC|BG_CONTAIN=15`），
> 不是"降级后的值"。**结论：现场只讲 `cfg_alive`/`cfg_stale`，不要讲 flags。**

> **【校准】4a 之后必须 `daemon-stop`，否则后半场会"没有 daemon"在管事。**
> 4a 只杀了 loader；`schedpilotd` 还活着，它的 pid 文件仍然有效。
> 于是 4b 的 `start` 会打印 `daemon already running pid=…` 并**跳过启动**，
> 而新 loader 重新 pin 的是**新的 map**——旧 daemon 的文件描述符还指着旧 map，
> 结果新调度器实际上以 loader 默认静态参数运行、没有分类在生效。
> 这就是本步加了 `daemon-stop` 的原因。如果你漏了它，现场会看到
> `daemon already running`（这本身是正常输出），但要知道此时分类是停的。

---

## 5. 收尾（约 5 秒）

```bash
scripts/schedpilotctl.sh rollback
cat /sys/kernel/sched_ext/state              # disabled
dmesg | grep -a sched_ext | tail -n 3        # 无 watchdog/stall
```

实际输出：

```
[schedpilot] rollback: stopping daemon + loader
[schedpilot] stopping loader pid=309759 (control detaches -> fair scheduler)
loader_pid=none daemon_pid=none
sched_ext.state=disabled
{"mode":2,"generation":1,"flags":15,"heartbeat_age_s":0,"class_map_entries":0,...}
[schedpilot] rollback ok (state=disabled)

[671953.895385] sched_ext: BPF scheduler "schedpilot" disabled (unregistered from user space)
[671956.054688] sched_ext: BPF scheduler "schedpilot" enabled
[671960.020415] sched_ext: BPF scheduler "schedpilot" disabled (unregistered from user space)
```

**讲解词**

- **做什么**：一条命令回滚，确认系统回到默认状态，并检查内核日志有没有异常。
- **说明什么**：整个实验过程 **0 次看门狗触发、0 次失速**。
- **我们的优势（用对照说明）**：我们把**内核自带的示例调度器 `scx_flatcg`** 放到同一个场景里，
  **10 轮全部被内核看门狗卸载**——这说明这个场景对调度器的容错要求有多苛刻，也说明我们做到了。
- **可以这样说**：
  > "一条命令回滚，系统回到默认状态。整个实验过程 0 次看门狗、0 次失速。作为对照，内核自带的
  > scx_flatcg 在同样场景下 10 轮全部被内核卸载——可见这个场景对调度器的要求有多苛刻。"

> **【校准】最后那行 `flags=15` 不要当成"降级证据"。** 它是 **loader 启动时写入的默认值**
> （`generation=1`、`flags=CLASS_DSQ|PREEMPT|LLC|BG_CONTAIN=15`），只说明"这套 pin 上没有 daemon 写过"。
> 想讲降级请用 §4b 的 `cfg_alive`/`cfg_stale`。详见 §4b 的警告框。

---

## 6. 现场应急预案（校准版）

| 情况 | 处置 |
|---|---|
| **D 轮数值异常波动** | **不要重跑**。口头说明"单轮受宿主噪声影响，以 20 轮冻结口径 +169.8% 为准"。若坚持重跑：`scripts/demo.sh 30 1`，约 100 秒。 |
| 端口/进程残留 | `scripts/schedpilotctl.sh rollback; bench/interference.sh stop; pkill -f '[a]bcd_experiment'`（**注意方括号**，见准备篇的警告） |
| 想展示 MySQL/Nginx | `bench/abcd_experiment.sh --workload mysql --runs 5 --duration 30 --arms A,D --results results/demo-mysql`（Nginx 同理，约 5 分钟；MySQL 需 `sysbench` 与 `MYSQL_CNF`） |
| 大屏想看实时计数器 | **新开一个终端**（需要真 TTY）：`watch -n1 'cat /sys/kernel/sched_ext/state; build/scx_schedpilot --stats \| head -n2'`。⚠️ 非交互/无 TTY 环境（如脚本里）`watch` 会报 `Error opening terminal: unknown`，改用 `while true; do clear; ...; sleep 1; done` |
| **`demo.sh` 跑完却没有 summary.md** | `abcd_experiment.sh` 默认 fail-fast：任一臂装载校验失败就 `exit 1`，**且不会写 summary.md**，此时 §2 那条 `sed` 会直接报错。处置：`ls -t results/ \| head`，看 `results/demo-*/invalid.log` 与 `invalid` 标记；`scripts/schedpilotctl.sh rollback; bench/interference.sh stop` 后重跑。 |
| 换机器/换用户后命令失效 | 全程需 **root**（非 root 时脚本会把 pid 目录退回 `/tmp/schedpilot`，而 §4 用的是 `/run/schedpilot/*.pid`）；`dmesg` 需 root 或 `dmesg_restrict=0`；实验脚本硬编码 CPU 0-3 / 4-7，**演示机需 ≥8 vCPU**（本机 16）。 |
| VM 没起来 | `ssh rd350x 'virsh -c qemu:///system start schedpilot-sp4'`，然后等约 20 秒再 `ssh schedpilot-sp4` |
| 现场被问到答不上来 | 见 `docs/06_demo_risks_qa.md`（含 12 条高频质疑的标准答案，含 LLC 消融、二进制溯源、SLO 口径） |

---

## 7. 附：几个必须先知道的口径真相

> 这三条是本次校准挖出来的，**评委有能力问到**。完整版与应对话术见 `docs/06_demo_risks_qa.md`。

1. **`d-no-llc` 消融在本 VM 上是空对照。**
   实测 `cfg_before.json`：D 臂 `flags=27`，`d-no-llc` 臂**也是 `flags=27`** —— 因为 daemon 检测到
   LLC 拓扑退化后自动关闭了 `llc_affinity`，所以 `--ablation llc_affinity=0` 什么都没改变。
   `d-no-bg` 是**有效**消融（`flags=19`，BG_CONTAIN 位确实清了）。
   → 对外只说 `d-no-bg` 的归因；`d-no-llc` 标注为"该 VM 上不构成有效对照（LLC 路由被自动关闭）"。

2. **二进制溯源：✅ 已闭合（最该主动讲的一条）。**
   - 头条 `+169.8%`（`formal-4`）来自 `be962b8` 构建（`9d1e904f` / `d02d4e0d`）；
   - 现场机器上跑的是 `loader 76f0cad3… / daemon 68e57608…`；
   - **我们在 HEAD `65c4485` 上做了干净重建，产物与现场二进制逐字节相同** ——
     即构建可复现、现场二进制就是 HEAD 源码树的产物（证据：`evidence/sp4-vm/formal-5/rebuild-proof.txt`）；
   - 并已用**同一套现场二进制**补跑正式矩阵 **`formal-5`**（A/D × 20 × 60s，**0 无效轮次**）：
     **QPS 中位 +183.8%、配对 +181.5% [+174.2, +188.8]，20/20 轮更高；p99 −34.8%；p50 −86.9%（约 7.6 倍）**；
     A 基线几乎不变（17274→17349），D 臂提升约 4.6%（v0.3.3 取消 `cache_slice` 自动收缩等改动）。
   → 被问到时说："冻结统计来自 v0.3.1 构建；我们在最终构建上补跑了 formal-5（20 轮、0 无效轮次），
   并验证过重建产物与现场二进制完全一致——**现场这个二进制就是头条数字的来源**。"

> ⚠️ 重建时务必记住：`scripts/build.sh --install` **只把 loader 装到 `/usr/local/bin/scx_schedpilot`，
> 不更新 `build/scx_schedpilot`**；而 `schedpilotctl.sh` 的 `loader_bin()` 优先用 `build/` 下的副本。
> 所以加了 `--install` 重建之后，演示实际跑的**仍是旧二进制**。正确做法：不加 `--install`。
   > ⚠️ 顺带记住：`scripts/build.sh --install` **不会更新 `build/scx_schedpilot`**（只装 `/usr/local/bin`），
   > 而 `schedpilotctl.sh` 优先用 `build/` 下的副本。重建时别加 `--install`，否则你跑的还是旧二进制。

3. **`goodput@SLO`（5ms）在冻结口径下等价于 QPS。**
   A 的 p99 只有 4.45ms < 5ms，所以固定 5ms 的 SLO 对两边都不"咬"，goodput ≈ QPS × 0.9995。
   别把它当第二个独立指标讲。**用 SLO 敏感性表**（基于 `formal-4` 的原始 `redis.out` 重算，
   两臂各 n=20，**无需重跑**）：

   | SLO | A 达标率 | D 达标率 | goodput 配对均值 | 单轮区间 |
   |---|---|---|---|---|
   | 5.0ms | 99.95% | 100.00% | +170.2% | +141.5% ~ +192.0% |
   | 4.5ms | 99.25% | 99.99% | +172.3% | +144.8% ~ +193.9% |
   | **4.0ms** | **87.63%** | **99.99%** | **+207.7%** | +175.1% ~ +233.0% |
   | 3.5ms | 50.26% | 99.90% | +436.4% | +377.6% ~ +482.1% |

   复算命令：`SP_SLO_MS=4.0 python3 bench/reparse_results.py results/formal-4 --slo-ms 4.0 && python3 bench/analyze_results.py --results results/formal-4 --baseline A`
   （⚠️ 会就地改写 `results/formal-4/` 的 summary.json；先备份或复制一份再跑。）

---

## 附：如果要现场跑正式口径

```bash
# Redis 旗舰矩阵：7 臂 × 20 轮 × 60 秒（约 3 小时，自动记录 commit/哈希/场景并 fail-fast）
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/demo-full
```

预期（与 `evidence/sp4-vm/formal-4/summary.md` 一致）：**D QPS 中位数 +172.5%（配对 +169.8%，20/20 轮更高）、
goodput@SLO(5ms) +173.1%、p99 −35.0%、p50 −86.2%**。

## 附：首次使用前提

```bash
# 1) 构建（在目标环境执行一次；本 VM 已构建）
KSRC=/usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64
scripts/build.sh --kernel-src "$KSRC" --install
# 2) 依赖：redis-server（bench 自动启动）、stress-ng、sysbench（MySQL 可选）
```

---

## 本次校准改了什么（2026-10-08 实机复跑）

| # | 位置 | 改动 | 原因 |
|---|---|---|---|
| 1 | 全文 | 新增"准备篇"（环境事实、上台前清场、时间轴） | 旧版没写"演示机是 rd350x 上的 VM"，且宿主 Ubuntu 完全跑不了 |
| 2 | 准备篇 | 新增 `pgrep -f` / `pkill -f` 自匹配警告 + 方括号写法 | 校准时两次杀掉自己的 SSH 会话 |
| 3 | 准备篇·时间轴 | `demo.sh 30 1` 标注实测 97s | 旧版写 ~100s（本来就准，这里给实测值） |
| 4 | 第 0 步 | "期望输出"补上被裁掉的 `schedpilotd --status` JSON 行 | 实际 `tail -n 8` 会多一行，且清场后可避免残留心跳值 |
| 5 | 第 1 步 | 增加 `flags=0x1b` 位含义解释 | 现场可视证据，且能自然引出 LLC 自动降级 |
| 6 | 第 2 步 | 增加两轮实测对比 + 单轮区间 + "不要报精确数字"话术 | 单轮 Δ% 实测 +159.6% / +193.2%，A 臂波动 ±7% |
| 7 | 第 2 步 | 讲解词补 `perf stat` 硬数据（16.9%→52.1% CPU、migrations 0→12188） | §6.11 已有，旧讲解词没用上 |
| 8 | 第 2 步 | 新增 **p50 −86%（7.2 倍）** 说法 | 冻结矩阵 20 轮实测 3.375→0.467ms；`04_test_report` §6.7 提过冻结前口径的 6.7×，但 README 头条 / PPT 提纲 / 旧版 runbook 都没用这个指标 |
| 9 | 第 3 步 | 补 `1 "class":"NORMAL"` 与 `numa_*` 字段的解释 | 实际输出比旧文档多 1 类，评委看得见 |
| 10 | 第 4a 步 | `pgrep -f` 改为读 pid 文件 | 自匹配风险 |
| 11 | 第 4a 步 | **加 `daemon-stop`**；说明漏掉它会"后半场没有 daemon 管事" | 4a 只杀 loader，存活 daemon 的 FD 指向旧 map，4b 的 `start` 会跳过启动 |
| 12 | 第 4b 步 | **fail-open 证据从 `flags` 改为 `cfg_alive`/`cfg_stale`**，并附实测四组计数 | 我最初用 `flags=15` 当证据是**错的**：15 是 loader 默认值，且杀 daemon 后 `flags` 仍为 27。BPF 从不回写 flags |
| 13 | 第 1 步 | 三段命令的输出分开标注；补 `--stats` 的顺序与"跳过 0 值计数器"两个坑 | 旧版把三条命令输出合成一段；`--stats` 第四行才是计数器且 0 值被跳过 |
| 14 | 第 2 步 | 补"单轮固定 A 先 D 后、无交织去偏、n=1 无 CI" | `demo.sh` 传 `--runs 1`，臂轮转 offset=0 |
| 15 | 第 6 步 | 应急预案补"无 summary.md"、root/pid/≥8 vCPU 前提；`watch` 补 TTY 限制；补 VM 没起来 | 实测重跑不划算；fail-fast 失败时不产 summary |
| 16 | 新增 §7 | LLC 空消融、二进制溯源、SLO 口径三条真相 | 本次校准最重要的三个发现 |
| 17 | **全文讲解词重写** | **新增"开场口播"（先讲清项目是什么）；6 段讲解词全部改为"做什么 → 说明什么 → 解决什么问题 → 我们的优势"结构，并各配一句可直接照读的口播示范** | 原讲解词偏"报数据 + 讲机制"，评委听不出"我们在干什么、这说明了什么" |
