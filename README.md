# SchedPilot

面向云原生高性能负载的 eBPF/sched_ext 用户态自适应调度系统

- 赛题：华为命题《基于 BPF/sched_ext 的用户态高性能动态调度器》（国产操作系统软件组）
- 状态：**v0.3.3 最终构建正式矩阵完成**（commit `65c4485`，Redis 混部场景 D vs 默认 fair **QPS 配对 +181.5%，20/20 轮更高**，n=20，0 无效轮次）；
  此前 v0.3.1 冻结构建（`be962b8`）为 +169.8%（`formal-4`），两代方向与量级一致，v0.3.3 略优
- 主环境：**openEuler 24.03 LTS SP4**（冻结矩阵）；**SP3 兼容验证通过**（自编译 sched_ext 内核，见 §6.12）；SP1 未验证
- Baseline 口径：**openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）**；不把 Linux 6.6 fair-class 内部实现等同于经典 CFS

## 核心结果（场景 v3：服务与干扰同 CPU 集，客户端隔离）

> **口径**：Redis 行引用**最终构建**（`formal-5`，commit `65c4485`，loader `76f0cad3` / daemon `68e57608`）；
> MySQL / Nginx 行引用其各自的冻结构建。**"现场会跑的二进制"就是 formal-5 的这一对**——
> 我们在 HEAD 上干净重建，产物与之逐字节一致（见 `evidence/sp4-vm/formal-5/rebuild-proof.txt`），溯源闭合。

| 负载 | 实验 | 最佳配置 | 相对默认 fair（配对逐轮复算） |
|---|---|---|---|
| Redis | **formal-5（A/D × 20×60s，最终构建）** | **D 全自适应** | **QPS 中位 +183.8%，配对 +181.5%（95% CI [+174.2%, +188.8%]，20/20 轮更高）**；goodput@SLO(5ms) 配对 +182.1%；p99 −34.8%；**p50 −86.9%（约 7.6 倍）** |
| Redis（前代口径） | formal-4（7 臂×20×60s，`be962b8`） | **D 全自适应** | QPS 中位 +172.5%，配对 +169.8% [+164.4, +175.2]，20/20；含 3 组消融 |
| MySQL | mysql-3（4 臂×10×60s） | **D 全自适应**（C 名义接近，差异在噪声内） | **TPS +85.2% [62.0, 108.3]**，p99 −74.8% [−82.4, −67.3] |
| Nginx | nginx-7（修正复跑，4 臂×20×60s） | **C/D 分类模式（`deploy_nginx.sh` 默认 adaptive）** | **D +169.8%（95% CI [+142.6%, +197.1%]，20/20 轮更高）**、C +167.8%；p99 均 **−69.6%**（20/20 轮更低）；basic 回退 +61.1% |

> **两处必须知道的口径边界（如实披露）**
> 1. **MySQL 的基线漂移**：`mysql-3` 的 A 臂基线中位 479.3 TPS，而 v0.3.3 构建下的
>    `v033-sanity` 复跑（`evidence/sp4-vm/v033-sanity/mysql-4-sanity-summary.md`，**n=5**）基线中位是
>    561.3 TPS——**相差 17%**，而 D 臂几乎不变（880.8 → 873.4），因此该次复跑的中位增益只有
>    **+55.6%**（配对 +73.88% [+39.78, +107.99]，5/5）。也就是说 MySQL 的 "+85.2%" 对基线状态相当敏感。
>    主结论仍以 n 更大的 `mysql-3` 为准，但引用时应说明这一点。
> 2. **Nginx / MySQL 的 A 臂是双峰的**：`nginx-7` 的 A 臂 20 轮在 12.1k–21.2k 之间（IQR 约为中位数的 35%），
>    `mysql-3` 类似；而 B/C/D 各臂的 IQR 只有 1%–3%。我们靠**逐轮配对**统计处理
>    （配对后 17–20/20 轮同向），但单看中位数比值会高估不确定性。

冻结证据（git commit + 二进制 SHA256 + 原始数据归档）见 `docs/04_test_report.md` §6.10（`be962b8` 冻结矩阵）
与 **§6.14（`65c4485` 最终构建矩阵 `formal-5`）**；
其中含 formal-3 回归的发现、消融根因（BG 切片 10ms→2ms 修复）与负结果保留。
统计口径：以逐轮配对复算（mean Δ% + 95% CI + 更高/更低轮数）为准；消融 vs D 的配对 CI 互相重叠，属趋势性结论。
无干扰回归（冻结 noif-2）：C/D 吞吐 −3.2%~−3.3%（10/10 轮为负）、p99 −11%~−12%；B 吞吐 −5.7%、p99 −17.6%——"少量吞吐换尾延迟"结构。
外部对照（冻结 ext-2）：内核树示例 scx_simple −51.7%（p99 +351.9%）；scx_flatcg **10/10 轮被内核 watchdog 卸载（无有效轮次）**。
稳定性（冻结构建）：故障注入 6/6 通过；15 分钟 soak 0 失速 PASS；正式矩阵 0 失速。
P1（v0.3.3）：cgroup/容器目标选择、动态 BG CPU pool、CUSUM 相位检测、NUMA locality 报告；
调度器开销实测 **≈0.24–0.28 μs/请求**（daemon；0.082 次派发/请求。原写 235 ns，因两个测量窗口不完全对齐已修正口径，见测试报告 §6.11）；构建/ABI 加固（intf fail-fast、干扰自检）。

## 闭环

```
Workload(Redis/Nginx/MySQL + CPU/内存干扰)
   │  eBPF: wakeup / runtime / run delay     userspace PMU: cycles/instructions/LLC（multiplex scaling）
   ▼
schedpilotd  EWMA + 非对称滞回三分类: L-SYNC / C-COMPUTE / M-BOUND（+ 显式 BG）
   │  pinned maps: class_map / cfg（generation + heartbeat + fail-open）
   ▼
scx_schedpilot (SCX_OPS)  LAT / COMP / CACHE 三路 DSQ（LLC 软亲和 / 迁移惩罚 / 预抢占）
```

## 仓库结构

```
bpf/            scx_schedpilot.bpf.c, intf.h          # sched_ext 数据面
loader/         scx_schedpilot.c                      # 调度器 loader
daemon/         schedpilotd + pmu_sampler/classifier/bpf_iface
configs/        schedpilot.conf / redis.conf / nginx.conf / mysql.conf
scripts/        env_check.sh build.sh build_external.sh schedpilotctl.sh demo.sh status_html.sh
bench/          run_{redis,nginx,mysql}.sh abcd_experiment.sh interference.sh
                parse_{redis,wrk,mysql}.py analyze_results.py reparse_results.py
tests/          classifier_test.cpp test_fault_injection.sh test_soak.sh
docs/           00_mvp_scope 02_test_plan 03_deploy_rollback 04_test_report
submission/     提交包索引（README / build_and_run / evidence_index）
.github/        CI（shell/python 检查 + daemon 构建 + 单元测试）
```

## 快速开始（目标环境 openEuler 24.03 LTS SP4）

```bash
scripts/env_check.sh --json evidence/sp4-vm/env_check.json     # 能力探测（sched_ext/BTF/PMU）
scripts/build.sh --kernel-src /usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64 --install
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
scripts/schedpilotctl.sh status

# 正式实验（Redis 旗舰；Nginx/MySQL 用 --workload nginx|mysql）
bench/abcd_experiment.sh --workload redis --runs 20 --duration 60 --warmup 10 \
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-4
# 外部对照（scx_simple / scx_flatcg）
scripts/build_external.sh
bench/abcd_experiment.sh --workload redis --runs 10 --duration 60 --warmup 10 \
  --arms A,B,D,X-simple,X-flatcg --results results/ext-1

# 测试与演示
make check                      # shell/python + 分类器单元测试
tests/test_fault_injection.sh   # 故障注入（loader/daemon kill、rollback）
tests/test_soak.sh --duration 1800
scripts/demo.sh                 # 一键演示（A vs D 快速曲线）
scripts/schedpilotctl.sh rollback
```

## 安全与 fail-open

- daemon 心跳超时（2s）→ BPF 使用静态安全参数，调度器不离场；
- loader 退出/kill → sched_ext 自动 detach → 默认 fair 调度器接管；
- 所有 knob 有上下界、generation、速率限制与默认值衰减；`rollback` 一键恢复。

## 文档

- 测试报告（含正式矩阵、消融、负结果）：`docs/04_test_report.md`
- **10 分钟演示流程（评审现场版，实机校准）**：`docs/05_demo_runbook.md`
- **演示前风险清单与答辩 Q&A（含审计发现与标准答案）**：`docs/06_demo_risks_qa.md`
- **答辩材料包（PPT 提纲 + 视频脚本 + Q&A）**：`submission/defense_pack.md`
- **项目说明书（docx/pdf）**：`submission/SchedPilot_项目说明书.docx` / `.pdf`
- 测试方案（场景 v3、客户端隔离、PMU scaling）：`docs/02_test_plan.md`
- 部署与回滚：`docs/03_deploy_rollback.md`
- MVP 范围与 P1/P2：`docs/00_mvp_scope.md`
- 总体方案与长期 roadmap：`SchedPilot_设计方案.md`
- 提交包索引：`submission/README.md`

## 后续规划（省赛后）

| 项 | 说明 | 优先级 |
|---|---|---|
| 单一最终构建全量矩阵 | ~~在 v0.3.3 最终构建上复跑 Redis/MySQL 正式矩阵（formal-5 / mysql-5）~~ **Redis 已完成（formal-5，A/D × 20 × 60s，配对 +181.5%，0 无效轮次）**；MySQL 的 `mysql-5` 仍可选 | P1（Redis 部分已完成） |
| 自动调参 | 爬山/贝叶斯优化替代规则型有界调整（MVP 已留旋钮与 generation 接口） | P2 |
| producer-consumer 识别 | 唤醒链同域共置（当前以 waker-LLC 启发式替代；本 VM 因 LLC 拓扑退化关路由） | P2 |
| NUMA 决策化 | 现为 locality 报告（`classifier.numa`）；下一步将其纳入 CACHE 路由/迁移决策 | P2 |
| BPF overhead 精确折算 | 当前内核不为 struct_ops 暴露 `run_time_ns`；待内核/工具支持后补测 | P2 |
| SP1 兼容验证 | SP3 已验证；SP1 镜像不可得，待获取后按 §6.12 方法复测 | P3 |
| 答辩材料成稿 | PPT 成稿 + 演示视频录制（提纲/脚本已就绪，见 `submission/defense_pack.md`） | 线下 |
| 容器资源模型深化 | cgroup 目标选择已实现；下一步结合容器 QoS/配额做类优先级映射 | P1 |
