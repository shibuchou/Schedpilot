# SchedPilot

面向云原生高性能负载的 eBPF/sched_ext 用户态自适应调度系统

- 赛题：华为命题《基于 BPF/sched_ext 的用户态高性能动态调度器》（国产操作系统软件组）
- 状态：**v0.3.1 冻结复跑完成**（commit `be962b8`，Redis 混部场景 D vs 默认 fair baseline **QPS 配对 +169.8%，20/20 轮更高**，n=20）
- 主环境：**openEuler 24.03 LTS SP4**（冻结）；SP1/SP3 仅作有时间时的兼容验证
- Baseline 口径：**openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）**；不把 Linux 6.6 fair-class 内部实现等同于经典 CFS

## 核心结果（场景 v3：服务与干扰同 CPU 集，客户端隔离；冻结矩阵 commit `be962b8`）

| 负载 | 实验 | 最佳配置 | 相对默认 fair（配对逐轮复算） |
|---|---|---|---|
| Redis | formal-4（7 臂×20×60s） | **D 全自适应** | **QPS +169.8%（95% CI [+164.4%, +175.2%]，20/20 轮更高）**；固定 SLO(5ms) goodput +170.2%；p99 −34.7% |
| MySQL | mysql-3（4 臂×10×60s） | **D 全自适应**（C 名义接近，差异在噪声内） | **TPS +85.2% [62.0, 108.3]**，p99 −74.8% [−82.4, −67.3] |
| Nginx | nginx-4（A,B×20×60s） | **B basic（推荐，`scripts/deploy_nginx.sh`）** | **QPS +50.1% [35.1, 65.2]**，p99 −34.1% [−43.5, −24.6]（17/20 轮更低） |

冻结证据（git commit + 二进制 SHA256 + 原始数据归档 + 0 无效轮次）见 `docs/04_test_report.md` §6.10；
其中含 formal-3 回归的发现、消融根因（BG 切片 10ms→2ms 修复）与负结果保留。
统计口径：以逐轮配对复算（mean Δ% + 95% CI + 更高/更低轮数）为准；消融 vs D 的配对 CI 互相重叠，属趋势性结论。
无干扰回归（冻结 noif-2）：C/D 吞吐 −3.2%~−3.3%（10/10 轮为负）、p99 −11%~−12%；B 吞吐 −5.7%、p99 −17.6%——"少量吞吐换尾延迟"结构。
外部对照（冻结 ext-2）：内核树示例 scx_simple −51.7%（p99 +351.9%）；scx_flatcg **10/10 轮被内核 watchdog 卸载（无有效轮次）**。
稳定性（冻结构建）：故障注入 6/6 通过；15 分钟 soak 0 失速 PASS；正式矩阵 0 失速。

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
- 测试方案（场景 v2、客户端隔离、PMU scaling）：`docs/02_test_plan.md`
- 部署与回滚：`docs/03_deploy_rollback.md`
- MVP 范围与 P1/P2：`docs/00_mvp_scope.md`
- 总体方案与长期 roadmap：`SchedPilot_设计方案.md`
- 提交包索引：`submission/README.md`
