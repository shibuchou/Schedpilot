# 证据索引

所有结论均可回溯到下列原始文件；缺失项一律标注“未执行/无效”。
Baseline 口径：openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）。
正式场景 v3：服务与干扰共享 CPU 0-3；客户端固定 4-7 并排除出分类目标。

## 目标环境能力

| 证据 | 位置 |
|---|---|
| SP4 VM 能力探测（OS/kernel/config/BTF/sched_ext/工具链/PMU） | `evidence/sp4-vm/env_check.json` |
| 开发机编译验证（rd350x） | `evidence/rd350x-dev-20260929/` |

## 最终正式矩阵（场景 v3，冻结提交 `be962b8`，0 无效轮次）

| 实验 | 内容 | 位置 | 结论（配对逐轮复算） |
|---|---|---|---|
| **formal-4** | Redis 7 臂 × 20 × 60s | `evidence/sp4-vm/formal-4/` | **D QPS +169.8% [+164.4, +175.2]，20/20 轮更高**；goodput@SLO +170.2%；p99 −34.7% |
| **mysql-3** | MySQL 4 臂 × 10 × 60s | `evidence/sp4-vm/mysql-3/` | **D TPS +85.2% [+62.0, +108.3]，10/10**；p99 −74.8% [−82.4, −67.3] |
| **nginx-4** | Nginx A,B × 20 × 60s | `evidence/sp4-vm/nginx-4/` | **B QPS +50.1% [+35.1, +65.2]，20/20**；p99 −34.1% [−43.5, −24.6]，17/20 轮更低（basic） |
| **nginx-5** | Nginx 分类模式复检 A,B,C,D × 10 × 60s | `evidence/sp4-vm/nginx-5/` | C +124.8% [+102.6, +146.9]，10/10；p99 −62.5% [−68.4, −56.6]，10/10（P1 尾延迟问题消除） |
| **nginx-6** | Nginx 分类模式正式确认 A,B,C,D × 20 × 60s | `evidence/sp4-vm/nginx-6/` | **C +143.1% [+118.7, +167.6]，20/20；p99 −66.3% [−70.5, −62.0]，20/20**（`deploy_nginx.sh` 默认 adaptive） |
| **noif-2** | Redis 无干扰 4 臂 × 10 × 60s | `evidence/sp4-vm/noif-2/` | C/D 吞吐 −3.2%~−3.3%（10/10 轮为负）、p99 −11%~−12%；B −5.7% / p99 −17.6% |
| **ext-2** | Redis 外部对照 5 臂 × 10 × 60s | `evidence/sp4-vm/ext-2/` | D +169.6% [+158.2, +181.1]；X-simple −51.3% / p99 +351.9%；X-flatcg **10/10 被 watchdog 卸载，无有效轮次** |

各实验的完整原始数据（每次运行的 workload 输出 / perf stat / daemon JSONL / cfg / 调度器状态 / dmesg）
保存在实验机的 `results/<experiment>/` 目录；本仓库 `evidence/sp4-vm/` 归档关键摘要（summary/meta/per_run/env_check）。

## 冻结归档（原始 tar.gz，SHA256）

归档存放于实验机 `/root/` 与本机 `D:\code\Ubuntu\raw-archive\`（仓库仅存摘要与哈希）：

| 归档 | 大小 (bytes) | SHA256 |
|---|---|---|
| formal-4-raw.tar.gz | 9874464 | `a19897bb02bc33df66d47b4a0702982d3308683ec45ea3ef4b9de232de278ac7` |
| mysql-3-raw.tar.gz | 1819807 | `1268cbbe64698bbea623d305e1366a0b10b63c0c90c5a82860563b40b313b137` |
| nginx-4-raw.tar.gz | 86662 | `3b56941af02b2e5af55ad0f41fed131ebfa722f35b8ab4699aaea1021216c6aa` |
| formal-3-raw.tar.gz（回归证据） | 18880184 | `d494f2929101ac75acb7934f92b86fc28cc0b49fd5a9c251906ceebb525746cd` |
| nginx-3-raw.tar.gz（冻结佐证） | 86091 | `5b4ae91c71a77a6ec51ebb51d0abaf94d9b9c3455ba8abd70cd2b2bf0853f82b` |
| noif-2-raw.tar.gz | 674444 | `fd1eff7061379d9ed603cb5faf38b88f21baa10cabc8293eb68497f5ce295c63` |
| ext-2-raw.tar.gz | 1599672 | `b79b2f622def4fb4b54fcaafb7a26bbfada3a95bd133a0d713376d671905e38c` |
| fault-soak-frozen-raw.tar.gz | 8449 | `55e9c4fb26aca804da3e4fc5877a65cdfdb1bbb04297200548389b605a4c96f9` |
| nginx-5-raw.tar.gz（分类模式复检） | 2080970 | `fcc394d0b5ddd93a33145246fed4dddb137e4d7ae998d53325b596045e142597` |
| nginx-6-raw.tar.gz（分类模式正式确认 n=20） | 4141887 | `ba1244b1f83f2935adefe83be8e01bf194c722cc4fe031ecc79c39f9e076f0e7` |
| smoke-cleanup-raw.tar.gz（死代码清理等价性 smoke） | 160111 | `9076f70d4c7335e351f15dc5ab256c3d5d424e6f2f81dbabb9b52580611db288` |
| sp3-evidence.tar.gz（SP3 兼容验证） | 1229434 | `e46976c23e1cb3030efd0895c853a2c1accb706d040bcfab371e567e3c128a5c` |

## 跨内核兼容（SP3，2026-10-05）

| 项 | 位置 | 结论 |
|---|---|---|
| SP3 自建 VM + `6.6.0-schedpilot-sp3` 自编译内核 | `evidence/sp3-vm/`（env_check / build.log） | 零改动编译通过、`make test` 通过、加载运行正常、15s 压测 0 失速 |
| Redis 迷你 A/D（2×20s） | `evidence/sp3-vm/sp3-hello/` | **D +129.0% QPS / p99 −30.6%**（方向与 SP4 一致，小样本） |

SP3 唯一 env_check FAIL 为 `tool.perf` 未安装（如实记录，不影响调度器）；SP1 未验证。

二进制 SHA256（三实验一致，见各自 `experiment.meta.json`）：
`scx_schedpilot` `9d1e904ff9ba9dd2ea6aa593a2be1720538a90c489d78d70d12fbf8f54cfd09f`、
`schedpilotd` `d02d4e0d8ae0cb77a5af98ee0be46adeda0a4575f6ef30c037d5bbb945d46e6a`、
`bpf_object` `a204183ae31cad8df960fb12e9c240797fdcbb8928a46f462ce059e00f35d206`。

## 冻结前历史矩阵（保留，作为方法学对照）

| 实验 | 内容 | 位置 | 结论 |
|---|---|---|---|
| formal-2 | Redis 7 臂 × 20 × 60s | `evidence/sp4-vm/formal-2/` | D +116.9% QPS、goodput@SLO +116.5%（`git_commit` 非最终提交） |
| mysql-2 | MySQL 4 臂 × 20 × 60s | `evidence/sp4-vm/mysql-2/` | D +62.4% TPS、p99 −77.2% |
| nginx-2 | Nginx 4 臂 × 20 × 60s | `evidence/sp4-vm/nginx-2/` | B +43.8% QPS、p99 −37.7%（推荐模式） |
| noif-1 | Redis 无干扰 4 臂 × 10 × 60s | `evidence/sp4-vm/noif-1/` | C/D 吞吐 −2.0%（10/10 轮为负）、p99 −12.7% |
| ext-1 | Redis 外部对照 5 臂 × 10 × 60s | `evidence/sp4-vm/ext-1/` | D +118.9%；scx_simple −49.7%（p99 +350%）；scx_flatcg +1.8% |

## 缺陷与无效数据（如实记录）

| 数据 | 判定 |
|---|---|
| nginx-1 / mysql-1 | **受污染、无效**：修复前二进制期间 scx watchdog `runnable task stall` 卸载 schedpilot 共 60 次（nginx-1 15 次、mysql-1 45 次）；仅作缺陷证据 |
| pilot-3/4/5 | 算法/场景迭代过程数据，不作为结论 |
| formal-1 | v1 轻干扰 + 修复前分类，保留为方法学对照 |

## 稳定性与测试

| 项 | 位置/结果 |
|---|---|
| 故障注入（loader/daemon kill、rollback） | `evidence/sp4-vm/fault-injection-final.log`（冻结前，6/6 PASS）；`evidence/sp4-vm/fault-injection-frozen.log`（`be962b8`，6/6 PASS） |
| 长稳 soak（D 臂持续压测） | VM `results/soak-final2/`（15 min，0 失速）；`results/soak-final/`（30 min，0 错误）；`evidence/sp4-vm/soak-frozen.log`（`be962b8`，15 min，49 周期，0 失速，PASS） |
| 单元测试 | `tests/classifier_test.cpp`（`make test`） |
| 看门狗证据 | VM `dmesg`：修复后各矩阵窗口 0 次 schedpilot 失速；flatcg 被卸载 10 次 |

## 二进制修订说明

实验贯穿多轮修复，各实验使用当时的二进制 revision；`experiment.meta.json` 记录 `git_commit`，
二进制 SHA256 以 VM `build/` 为准。修复后的最终代码以本仓库 git 提交为准确认。
