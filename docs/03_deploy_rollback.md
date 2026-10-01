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
scripts/build.sh --kernel-src /root/kernel-src --install
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

一键演示流程（省赛）：

```bash
scripts/env_check.sh && make && scripts/schedpilotctl.sh start --mode adaptive \
  && bench/abcd_experiment.sh --runs 3 --duration 30 --arms D   # 演示版快速曲线
```

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
