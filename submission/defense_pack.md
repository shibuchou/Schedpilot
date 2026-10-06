# SchedPilot 省赛答辩与演示材料包

本文覆盖两件交付：**① 答辩 PPT 提纲（10 页）**；**② 10 分钟演示视频/现场脚本（与 `docs/05_demo_runbook.md` 一致，全部命令实测）**。
所有数据引用自 `docs/04_test_report.md`（§6.7–§6.12）与 `submission/evidence_index.md`。

---

## 一、PPT 提纲（10 页，含每页要点与用图）

| 页 | 标题 | 要点 | 建议用图/证据 |
|---|---|---|---|
| 1 | 封面 | 赛题：华为命题《基于 BPF/sched_ext 的用户态高性能动态调度器》；一句话价值：**混部场景把尾延迟敏感服务的吞吐提升 1.7 倍、p99 降三成**；队名/成员 | 一张 A vs D 对比数字卡（+169.8% / −34.7%） |
| 2 | 赛题理解与痛点 | 云原生混部：干扰共置 → fair 调度器只拿 16.7% CPU；用户态不可编程；需要在**内核数据面 + 用户态控制面**之间做"感知-决策-执行"闭环 | `CPU 占用 16.7%→49.9%` 柱状（§6.11） |
| 3 | 总体架构 | 数据面 `scx_schedpilot`（LAT/COMP/CACHE 三 DSQ + BEST 回退）；控制面 `schedpilotd`（100ms 采样→三分类→有界 knob）；pinned maps + generation + 心跳 fail-open | 架构图（闭环框图：Workload→eBPF事件+PMU→分类→DSQ） |
| 4 | 数据面设计 | L-SYNC 短片优先+唤醒预抢占；C-COMPUTE 公平 vtime；M-BOUND 长片+LLC 软亲和+迁移惩罚上限；**BG 收容：短切片(2ms)×vtime×2** | DSQ/切片参数表；`bg_slice` 不变式注释 |
| 5 | 控制面与分类器 | 调度事件（wake rate/run/delay/切换）+ PMU（IPC/MPKI）→ EWMA+非对称滞回三分类；BG 显式配置；自适应旋钮全部有界、可消融 | JSONL 样例（L-SYNC/BG/M-BOUND 各一条，含特征） |
| 6 | 工程正确性（亮点） | **formal-3 冻结复跑发现真实回归**（D 仅 +16.4%、p99≈10ms）→ 消融二分（pilot-6→9）定位"LAT 预抢占限流 + bg_slice 10ms" → 修复后 formal-4 +172.5%；全过程数据/哈希/负结果保留 | 回归时间线图（+16.4% → +172.5%）；表：pilot-8/9 关键点 |
| 7 | 三负载正式结果 | Redis D **+169.8%（20/20）**、goodput +170.2%、p99 −34.7%；MySQL +85.2%、p99 −74.8%；Nginx 分类模式 C **+124.8%、p99 −62.5%**（推荐 adaptive） | 三负载配对 CI 森林图（或三张小抄表） |
| 8 | 消融与外部对照 | B/C/D 递进归因；3 组消融 CI 重叠→趋势性（如实）；**scx_simple −51.7%/p99+351%，scx_flatcg 10/10 被内核看门狗卸载**——通用调度器在该场景不可用 | 消融/对照表（ext-2）+ flatcg 卸载 dmesg 截图 |
| 9 | 稳定性与兼容 | 0 watchdog/失速；故障注入 6/6；soak 0 失速；**SP3 自编译内核零改动编译通过、加载运行、迷你 A/D +129%** | `sched_ext state=enabled` 截图；SP3 结果小卡 |
| 10 | 演示与交付 | 10 分钟演示；一键脚本；证据链（commit+SHA256+原始归档）；未来：CUSUM 相位、NUMA、动态 BG pool | 仓库结构/Q R 码（提交包索引）；演示截图 |

口播合计约 8–10 分钟，建议第 6 页（回归故事）与第 8 页（flatcg 对照）各多花 30 秒——这是"真实性"最有杀伤力的两页。

---

## 二、10 分钟演示脚本（现场或录屏）

> 环境：实验 VM（`schedpilot-sp4`）。录屏时建议 1080p、单窗口全屏终端 + 一个 `watch` 副窗。
> 所有命令与预期输出见 `docs/05_demo_runbook.md`（已全部实测）。

| 时间 | 画面/操作 | 口播要点 |
|---|---|---|
| 0:00–0:40 | PPT 第 1–2 页（封面+痛点） | "云原生混部下，默认 fair 调度器在本机只给 Redis 16.7% 的 CPU；我们要在 sched_ext 上做用户态可编程调度，把'该快的快、该让的让'变成闭环。" |
| 0:40–1:30 | 切终端：`scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf` + `status` + `build/scx_schedpilot --stats \| head` | "一条命令加载数据面+控制面：三条 DSQ、100ms 分类回路、心跳 fail-open。state=enabled 即生效。" |
| 1:30–2:00 | `sed -n '1,16p' $(ls -td results/demo-* \| head -n1)/summary.md`（先跑一次或在 2 段后展示） | "这是快速 A/D 对比：A 是默认 fair，D 是 SchedPilot。同 CPU 干扰、同负载。" |
| 2:00–4:40 | 运行 `scripts/demo.sh 30 1`（自动：干扰+两轮+汇总） | 讲解运行中的画面（ping 不关）；结果宣读："A 19467 → D 50539 QPS，+159.6%；p99 4.42ms → 2.89ms，−34.7%。正式 20 轮统计是 +169.8%、20/20 全胜。" |
| 4:40–5:30 | `grep -m2 '"class":"L-SYNC"' $RUN/D/run-01/logs/*.jsonl` + `grep -m2 '"class":"BG"'` | "每一次分类都有可审计日志：redis-server 被判 L-SYNC（高唤醒+高 IPC），stress-ng 是显式 BG——不是黑盒调参。" |
| 5:30–6:30 | 故障演示：`kill -9 $(pgrep -f 'scx_schedpilot --mode')` → `cat /sys/kernel/sched_ext/state` = disabled | "调度器在内核里必须能被信任：loader 挂了，内核自动切回 fair，业务无损；daemon 挂了 BPF 保持安全参数。故障注入 6/6 通过。" |
| 6:30–8:00 | PPT 第 6–8 页（回归故事 + 三负载 + flatcg） | 口播回归故事 45 秒：formal-3 暴露回归 → 二分定位 bg_slice → 修复 +172.5%；再讲 15 秒 flatcg 被看门狗卸载 10/10。 |
| 8:00–9:00 | `scripts/deploy_nginx.sh`（adaptive 默认）或 PPT 第 9 页 | "MySQL/Nginx 同样是净收益：Nginx 从'推荐 basic'升级为分类模式 +124.8%/p99 −62.5%；SP3 内核兼容也过了。" |
| 9:00–10:00 | `scripts/schedpilotctl.sh rollback` + `dmesg \| grep -a sched_ext \| tail` + PPT 第 10 页 | "一键回滚、0 失速；证据链在仓库（commit/SHA256/原始归档）。谢谢。" |

**录屏注意事项**

- 提前：`scripts/schedpilotctl.sh rollback`、`bench/interference.sh stop`，避免端口/进程残留。
- `demo.sh` 结果目录带时间戳，脚本里用 `ls -td results/demo-* | head -n1` 取最新。
- 若担心现场抖动：多跑一次 `demo.sh 30 1`，取更好的一轮录屏；正式数据始终引用 20 轮矩阵。

---

## 三、答辩 Q&A 速查（高频问题与答案要点）

| 问题 | 答案要点 |
|---|---|
| 为什么不直接用 scx_layered/scx_flatcg？ | 通用 DSL 需要人工写层规则；我们在场景内自动分类+自适应，且同场景实测 flatcg 被内核看门狗卸载 10/10、simple 吞吐 −51.7%。 |
| p99 为什么不是大幅优化？ | 主指标是吞吐/goodput；p99 受干扰片长约束（≈各臂 4.5ms 底线）。正式口径：goodput@5ms +170.2%，p99 −34.7%（配对，20/20 更低）。 |
| 消融的 CI 为什么重叠？ | 修复后各消融臂与 D 差异 ≤2.2pp 且 CI 重叠——如实标注为趋势性，不以单组消融宣称机制占比；主收益来自 sched_ext 基础+三分类（B/C 步骤）。 |
| 你们如何保证不"调数据"？ | 全流程冻结：commit/SHA256/场景写 meta；fail-fast+污染检测（INVALID）；formal-3 回归与 ext-2 flatcg 卸负结果全部保留；原始 tar 归档+sha256。 |
| 用户态分类延迟会不会太慢？ | 决策周期 100ms（慢回路），快路径 O(1) 查表 + 心跳/generation 校验；分类只影响 DSQ/切片，不经用户态转发任务。 |
| 容器场景支持吗？ | 支持 cgroup v2 子树目标选择（`configs/cgroup-demo.conf`，递归 `cgroup.procs`，白名单校验）；回归测试 `tests/test_cgroup_targeting.sh`。 |
