// SPDX-License-Identifier: MIT
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "intf.h"

namespace sp {

// Read/write access to the pinned maps exposed by scx_schedpilot.
class BpfIface {
public:
	bool open_maps(std::string *err, const std::string &base =
					  "/sys/fs/bpf/schedpilot/v1");
	bool ready() const { return cfg_fd_ >= 0; }

	bool cfg_get(sp_cfg *out);
	bool cfg_set(const sp_cfg &in);

	bool class_set(uint32_t tgid, const sp_task_class &c);
	bool class_del(uint32_t tgid);
	bool class_count(uint32_t *count);

	bool tg_stats_get(uint32_t tgid, sp_tg_stats *out);
	bool tg_stats_del(uint32_t tgid);
	bool tg_stats_next(uint32_t *key, uint32_t *next_key, bool *found);

	bool stats_read(std::vector<uint64_t> *out);
	bool cpu_llc_set(uint32_t cpu, uint32_t llc);

	int nr_cpus() const { return nr_cpus_; }
	const std::string &base() const { return base_; }

private:
	std::string base_;
	int cfg_fd_ = -1;
	int class_fd_ = -1;
	int tg_fd_ = -1;
	int stats_fd_ = -1;
	int llc_fd_ = -1;
	int nr_cpus_ = 1;
};

} // namespace sp
