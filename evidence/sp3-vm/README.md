# SP3 兼容验证证据（2026-10-05）

- `env_check.json`：SP3 VM 完整探测输出（OK=30 WARN=4 FAIL=1；唯一 FAIL 为 `tool.perf` 未安装）。
- `build.log`：`scripts/build.sh --kernel-src /usr/src/linux-6.6.0-145.3.34.165.oe2403sp3.x86_64`
  全量构建日志（BUILD_EXIT=0）。
- `sp3-hello/`：Redis 迷你 A/D（2×20s）摘要、逐轮数据与 meta
  （**D +129.0% QPS / p99 −30.6%**，方向与 SP4 正式矩阵一致；小样本仅作可用性佐证）。

环境：openEuler 24.03 LTS-SP3 KVM（RD350x 宿主，8 vCPU/16 GiB/桥接 phybr0）；
发行版内核无 `CONFIG_SCHED_CLASS_EXT`，以 SP3 源码重建 `6.6.0-schedpilot-sp3`
（新增 `SCHED_CLASS_EXT=y`、`EXT_GROUP_SCHED=y`，清空 trusted keys，`LOCALVERSION=-schedpilot-sp3`），
grub 默认项持久生效。完整原始归档 `sp3-evidence.tar.gz`
（sha256 `e46976c23e1cb3030efd0895c853a2c1accb706d040bcfab371e567e3c128a5c`）存放于
SP3 VM `/root/` 与本机 `D:\code\Ubuntu\raw-archive\`。
