# SchedPilot

面向云原生高性能负载的 eBPF/sched_ext 用户态自适应调度系统

- 赛题：华为命题《基于 BPF/sched_ext 的用户态高性能动态调度器》（国产操作系统软件组）
- 状态：**v0.3.0-mvp 完成闭环与正式验收**（Redis 混部场景 D vs 默认 fair baseline **+116.9% 吞吐**，p<0.0001，n=20）
- 主环境：**openEuler 24.03 LTS SP4**（冻结）；SP1/SP3 仅作有时间时的兼容验证
- Baseline 口径：**openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）**；不把 Linux 6.6 fair-class 内部实现等同于经典 CFS

## 核心结果（场景 v3：服务与干扰同 CPU 集，客户端隔离）

| 负载 | 实验 | 最佳配置 | 相对默认 fair（配对逐轮复算） |
|---|---|---|---|
| Redis | formal-2*（7 臂×20×60s） | **D 全自适应** | **QPS +116.8%（95% CI [+111.9%, +121.7%]，20/20 轮更高）**；固定 SLO(5ms) goodput +116.2% |
| MySQL | mysql-2*（4 臂×20×60s） | **D 全自适应** | **TPS +77.5% [58.7, 96.3]**，p99 −68.2% [−75.9, −60.5] |
| Nginx | nginx-2*（4 臂×20×60s） | **B basic（推荐，`scripts/deploy_nginx.sh`）** | **QPS +54.3% [39.2, 69.4]**，p99 −37.3% [−45.2, −29.4]（18/20 轮更低） |

`*` 冻结前版本；冻结版复跑（formal-3/nginx-3，含 git commit + 二进制 SHA256 + 原始数据归档）见 `docs/04_test_report.md` §6.10。
统计口径：以逐轮配对复算（mean Δ% + 95% CI + 更高/更低轮数）为准；消融 vs D 的配对 CI 跨 0，属趋势性结论。
无干扰回归：C/D 吞吐系统性 −2.0% 左右（10/10 轮为负）、p99 −12.7%——即"少量吞吐换尾延迟"的结构，不表述为回归受控。
外部对照：内核树示例 scx_simple −49.7%（p99 +350%）、scx_flatcg +1.8%。
稳定性：故障注入 6/6 通过；修复 sched_ext watchdog 失速后，正式矩阵 0 失速。

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
  --arms A,B,C,D,d-no-pmu,d-no-llc,d-no-bg --results results/formal-2
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
