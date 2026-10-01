// SPDX-License-Identifier: MIT
#include "bpf_iface.hpp"

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

namespace sp {

static int open_pinned(const std::string &base, const char *name)
{
	std::string path = base + "/" + name;
	return bpf_obj_get(path.c_str());
}

bool BpfIface::open_maps(std::string *err, const std::string &base)
{
	base_ = base;
	cfg_fd_ = open_pinned(base_, "cfg");
	class_fd_ = open_pinned(base_, "class_map");
	tg_fd_ = open_pinned(base_, "tg_stats");
	stats_fd_ = open_pinned(base_, "stats");
	llc_fd_ = open_pinned(base_, "cpu_llc");
	nr_cpus_ = libbpf_num_possible_cpus();
	if (nr_cpus_ <= 0)
		nr_cpus_ = 1;

	if (cfg_fd_ < 0 || class_fd_ < 0 || tg_fd_ < 0 || stats_fd_ < 0 ||
	    llc_fd_ < 0) {
		if (err) {
			*err = "cannot open pinned maps under " + base_ +
			       " (is scx_schedpilot running?)";
		}
		return false;
	}
	return true;
}

bool BpfIface::cfg_get(sp_cfg *out)
{
	uint32_t key = 0;
	return cfg_fd_ >= 0 &&
	       bpf_map_lookup_elem(cfg_fd_, &key, out) == 0;
}

bool BpfIface::cfg_set(const sp_cfg &in)
{
	uint32_t key = 0;
	return cfg_fd_ >= 0 &&
	       bpf_map_update_elem(cfg_fd_, &key, &in, BPF_ANY) == 0;
}

bool BpfIface::class_set(uint32_t tgid, const sp_task_class &c)
{
	return class_fd_ >= 0 &&
	       bpf_map_update_elem(class_fd_, &tgid, &c, BPF_ANY) == 0;
}

bool BpfIface::class_del(uint32_t tgid)
{
	return class_fd_ >= 0 && bpf_map_delete_elem(class_fd_, &tgid) == 0;
}

bool BpfIface::class_count(uint32_t *count)
{
	if (class_fd_ < 0)
		return false;
	uint32_t cur = 0, next = 0, n = 0;
	bool has = bpf_map_get_next_key(class_fd_, nullptr, &next) == 0;
	while (has) {
		n++;
		cur = next;
		has = bpf_map_get_next_key(class_fd_, &cur, &next) == 0;
		if (n > 1000000)
			break;
	}
	*count = n;
	return true;
}

bool BpfIface::tg_stats_get(uint32_t tgid, sp_tg_stats *out)
{
	return tg_fd_ >= 0 && bpf_map_lookup_elem(tg_fd_, &tgid, out) == 0;
}

bool BpfIface::tg_stats_del(uint32_t tgid)
{
	return tg_fd_ >= 0 && bpf_map_delete_elem(tg_fd_, &tgid) == 0;
}

bool BpfIface::tg_stats_next(uint32_t *key, uint32_t *next_key, bool *found)
{
	if (tg_fd_ < 0)
		return false;
	*found = bpf_map_get_next_key(tg_fd_, key, next_key) == 0;
	return true;
}

bool BpfIface::stats_read(std::vector<uint64_t> *out)
{
	if (stats_fd_ < 0)
		return false;

	out->assign(SP_NR_STATS, 0);
	std::vector<uint64_t> vals(nr_cpus_, 0);
	for (uint32_t idx = 0; idx < SP_NR_STATS; idx++) {
		if (bpf_map_lookup_elem(stats_fd_, &idx, vals.data()) != 0)
			continue;
		uint64_t sum = 0;
		for (int cpu = 0; cpu < nr_cpus_; cpu++)
			sum += vals[cpu];
		(*out)[idx] = sum;
	}
	return true;
}

bool BpfIface::cpu_llc_set(uint32_t cpu, uint32_t llc)
{
	return llc_fd_ >= 0 && bpf_map_update_elem(llc_fd_, &cpu, &llc, BPF_ANY) == 0;
}

} // namespace sp
