This directory vendors the sched_ext C headers used for *development builds*
on machines whose running kernel image is newer than the target (for example
an Ubuntu box used only for compile checks).

Origin:
- Copied from a local copy of the Linux kernel `tools/sched_ext/include/scx/`
  tree shipped inside the OSPP-2025 `lock-sched` reference project
  (lmp/OSPP/OSPP2025/.../lock-sched/tools/sched_ext/include/scx).
- The tree carries the 6.12+ DSQ API (`scx_bpf_dsq_insert`,
  `scx_bpf_dsq_insert_vtime`) plus the `compat.bpf.h` shim layer and generated
  enum headers.

License:
- These headers are GPL-2.0 (they carry the original SPDX identifiers). The
  SchedPilot BPF program links against them and is therefore distributed as
  GPL-2.0. The user-space daemon and scripts are MIT.

Target builds (openEuler 24.03 LTS SP4):
- `scripts/build.sh --kernel-src <KERNEL_SRC>` copies the scheduler sources
  into `<KERNEL_SRC>/tools/sched_ext` and builds with the exact headers of the
  frozen target kernel. That path is authoritative for competition results;
  this vendored copy exists so `make` can compile-check the BPF object on any
  dev machine with clang >= 18 and libbpf headers.
