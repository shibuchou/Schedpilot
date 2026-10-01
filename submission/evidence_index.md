# 证据索引

所有结论均可回溯到下列原始文件；缺失项一律标注“未执行/无效”。
Baseline 口径：openEuler 默认 fair-class 调度器（赛题表述为默认 CFS）。
正式场景 v3：服务与干扰共享 CPU 0-3；客户端固定 4-7 并排除出分类目标。

## 目标环境能力

| 证据 | 位置 |
|---|---|
| SP4 VM 能力探测（OS/kernel/config/BTF/sched_ext/工具链/PMU） | `evidence/sp4-vm/env_check.json` |
| 开发机编译验证（rd350x） | `evidence/rd350x-dev-20260929/` |

## 最终正式矩阵（场景 v3）

| 实验 | 内容 | 位置 | 结论 |
|---|---|---|---|
| **formal-2** | Redis 7 臂 × 20 × 60s | `evidence/sp4-vm/formal-2/` | **D +116.9% QPS**（p<0.0001）、goodput@SLO +116.5% |
| **mysql-2** | MySQL 4 臂 × 20 × 60s | `evidence/sp4-vm/mysql-2/` | **D +62.4% TPS、p99 −77.2%**（p<0.0001） |
| **nginx-2** | Nginx 4 臂 × 20 × 60s | `evidence/sp4-vm/nginx-2/` | **B +43.8% QPS、p99 −37.7%**（p<0.0001，推荐模式） |
| **noif-1** | Redis 无干扰 4 臂 × 10 × 60s | `evidence/sp4-vm/noif-1/` | C/D 吞吐 ±2% 内、p99 −13.2% |
| **ext-1** | Redis 外部对照 5 臂 × 10 × 60s | `evidence/sp4-vm/ext-1/` | D +118.9%；scx_simple −49.7%（p99 +350%）；scx_flatcg +1.8% |

VM 全量原始数据（每次运行的 workload 输出 / perf stat / daemon JSONL / cfg / 调度器状态 / dmesg）：

```
schedpilot-sp4:/root/schedpilot/results/{formal-2,mysql-2,nginx-2,noif-1,ext-1,...}
```

## 缺陷与无效数据（如实记录）

| 数据 | 判定 |
|---|---|
| nginx-1 / mysql-1 | **受污染、无效**：修复前二进制期间 scx watchdog `runnable task stall` 卸载 schedpilot 共 60 次（nginx-1 15 次、mysql-1 45 次）；仅作缺陷证据 |
| pilot-3/4/5 | 算法/场景迭代过程数据，不作为结论 |
| formal-1 | v1 轻干扰 + 修复前分类，保留为方法学对照 |

## 稳定性与测试

| 项 | 位置/结果 |
|---|---|
| 故障注入（loader/daemon kill、rollback） | `evidence/sp4-vm/fault-injection-final.log`，6/6 PASS |
| 长稳 soak（D 臂持续压测） | VM `results/soak-final2/`（15 min，0 失速）；`results/soak-final/`（30 min，0 错误） |
| 单元测试 | `tests/classifier_test.cpp`（`make test`） |
| 看门狗证据 | VM `dmesg`：修复后各矩阵窗口 0 次 schedpilot 失速；flatcg 被卸载 10 次 |

## 二进制修订说明

实验贯穿多轮修复，各实验使用当时的二进制 revision；`experiment.meta.json` 记录 `git_commit`，
二进制 SHA256 以 VM `build/` 为准。修复后的最终代码以本仓库 git 提交为准确认。
