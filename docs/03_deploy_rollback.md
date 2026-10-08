# SchedPilot 部署与回滚（openEuler 24.03 LTS SP4）

## 1. 前置条件

| 项 | 要求 | 检查 |
|---|---|---|
| 内核 | 启用 `CONFIG_SCHED_CLASS_EXT=y`（backport 或自编译） | `scripts/env_check.sh` |
| 内核 BTF | `CONFIG_DEBUG_INFO_BTF=y` 且 `/sys/kernel/btf/vmlinux` 存在 | 同上 |
| 工具链 | clang ≥ 17（推荐 18）、libbpf-dev、bpftool、g++ ≥ 11 | 同上 |
| 权限 | root（加载 sched_ext、PMU 采样、pinned bpffs） | `id -u` |
| 干扰工具 | `stress-ng`；客户端 `redis-benchmark`（或独立机器） | 同上 |
| 目标内核源码 | `<KERNEL_SRC>/tools/sched_ext`（与运行内核一致） | 构建脚本会校验 |

## 2. 构建

```bash
# 目标环境（权威构建，使用目标内核树 sched_ext 头文件）：
KSRC=/usr/src/linux-6.6.0-<ver>.oe2403sp4.x86_64   # 按实际内核源码树替换
scripts/build.sh --kernel-src "$KSRC" --install
# -> /usr/local/bin/scx_schedpilot（loader）
# -> build/schedpilotd          （daemon）

# 开发机快速编译检查（Linux，clang/libbpf 就绪）：
scripts/build.sh --dev [--vmlinux /path/to/vmlinux.h]
```

## 3. 部署与启动

```bash
scripts/schedpilotctl.sh start --mode adaptive --config configs/redis.conf
scripts/schedpilotctl.sh status
# 观察：
#   /sys/kernel/sched_ext/state = enabled，ops 含 schedpilot
#   build/schedpilotd --dump-cfg 输出 mode=2
#   logs/schedpilotd-*.jsonl 持续出现 sample 事件
```

一键演示流程（省赛）：**见 `docs/05_demo_runbook.md`（实机校准版）**。

```bash
# 推荐：一行搞定（环境自检 → A/D 两轮 → 汇总 → 自动回滚），实测约 97 秒
scripts/demo.sh 30 1
```

> ⚠️ **不要用下面这种写法**：它**没有基线臂 A**，因此 `analyze_results.py` 拿不到 baseline，
> summary 里的对比列会全空（旧版本这里的示例是 `--arms D`，已删除）。
> 需要 A/D 对比时至少写 `--arms A,D` —— `demo.sh` 已经把这些封装好了：
> `bench/abcd_experiment.sh --workload redis --runs 1 --duration 30 --warmup 5 --arms A,D --results results/demo-<ts>`

## 3.1 容器 / cgroup 目标选择（P1 已实现）

除按进程名选择目标外，daemon 支持按 **cgroup v2 子树**选择（容器、systemd scope/slice、
Podman/Docker 场景）：配置 `targets.cgroup_paths` / `bg.cgroup_paths`，递归读取每个子树的
`cgroup.procs`，其进程自动成为普通目标 / BG 目标（仍受 `exclude_names` 约束；路径必须在
`/sys/fs/cgroup` 下）。与按名匹配可叠加使用，示例配置 `configs/cgroup-demo.conf`。

```bash
# 示例：把 redis 与 stress-ng 分别放进两个 cgroup，再用 cgroup 配置上线
mkdir -p /sys/fs/cgroup/schedpilot-test/{redis,stress}
( echo $BASHPID > /sys/fs/cgroup/schedpilot-test/redis/cgroup.procs; exec redis-server --port 6399 --save "" --appendonly no ) &
( echo $BASHPID > /sys/fs/cgroup/schedpilot-test/stress/cgroup.procs; exec stress-ng --cpu 4 --timeout 60s ) &
scripts/schedpilotctl.sh start --mode adaptive --config configs/cgroup-demo.conf

# 回归测试（dry-run，无需加载 BPF 调度器即可验证发现与标注；自动探测/
# 按需挂载 cgroup2，兼容 legacy v1 布局）
tests/test_cgroup_targeting.sh
```

## 3.2 P1 旋钮（全部 opt-in，默认不影响既有行为）

| 配置 | 默认 | 作用 | 验证 |
|---|---|---|---|
| `targets.cgroup_paths` / `bg.cgroup_paths` | 空 | 按 cgroup v2 子树选择目标（§3.1） | `tests/test_cgroup_targeting.sh` 5/5 |
| `bg.cpu_pool` | 空 | 动态 BG CPU 池：非 BG 目标存在时把 BG 任务全部线程钉到池 CPU；目标消失自动恢复原亲和 | `tests/test_bg_cpu_pool.sh` 5/5 |
| `classifier.cusum` | false | CUSUM 相位检测：工作负载电平突变时一次性绕过滞回（JSONL 含 `phase` 标记） | `make test`（≤2 周期 vs ≥3 周期） |
| `classifier.numa` | true | NUMA locality **报告**（JSONL `numa_local_pct/numa_nodes`），不参与决策 | 集成测试断言字段存在 |
| `classification.cusum_h/slack` | 5.0 / 0.5 | CUSUM 阈值与单步容忍漂移 | 同上 |

开销折算：`bench/measure_overhead.sh --duration 20`（需调度器在线）输出 daemon CPU、派发频次、
每请求折算（内核 BPF struct_ops runtime 在当前 6.6 backport 不单独暴露）。

## 4. 停止与回滚

```bash
scripts/schedpilotctl.sh stop       # 停 daemon + loader -> 自动回默认 fair 调度器
scripts/schedpilotctl.sh rollback   # stop + 校验 schedpilot 已注销
```

安全语义：

- daemon 死亡 → BPF 心跳超时（2s）→ adaptive 模式自动使用静态安全参数；调度器不退出。
- loader 死亡/退出 → sched_ext 自动 detach → 默认 fair 调度器接管，任务不丢。
- watchdog：scx 内核看门狗超时会自动 abort 调度器并记录 exit info（`schedpilot unloaded (ecode=...)`）。
- `--detach` 拒绝全局 pkill 式清理；只允许通过记录 PID 的 `schedpilotctl.sh stop`。

## 5. 故障排查

| 症状 | 排查 |
|---|---|
| daemon 报 `cannot open pinned maps` | loader 未运行或 pin 路径不对：`ls /sys/fs/bpf/schedpilot/v1` |
| PMU 日志 `unavailable` | `perf_event_paranoid`、是否 root、VM 是否暴露 vPMU；见测试报告降级路径 |
| 调度器未生效 | `cat /sys/kernel/sched_ext/state`；`dmesg \| tail` 查 verifier/load 错误 |
| 性能回退 | `schedpilotctl.sh rollback`；检查 cfg 的 slice/权重是否符合预期（`--dump-cfg`） |
