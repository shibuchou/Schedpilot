// SPDX-License-Identifier: MIT
#pragma once

#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace sp {

inline std::string trim(const std::string &s)
{
	size_t b = s.find_first_not_of(" \t\r\n");
	if (b == std::string::npos)
		return "";
	size_t e = s.find_last_not_of(" \t\r\n");
	return s.substr(b, e - b + 1);
}

inline std::vector<std::string> split_list(const std::string &s)
{
	std::vector<std::string> out;
	std::string cur;
	for (char c : s) {
		if (c == ',' || c == ' ' || c == '\t') {
			if (!cur.empty()) {
				out.push_back(cur);
				cur.clear();
			}
		} else {
			cur += c;
		}
	}
	if (!cur.empty())
		out.push_back(cur);
	return out;
}

// Flat key=value config with optional [section] prefixes ("section.key").
class Config {
public:
	std::map<std::string, std::string> kv;
	std::string path;

	static Config load(const std::string &path)
	{
		Config cfg;
		cfg.path = path;
		std::ifstream in(path);
		if (!in) {
			throw std::runtime_error("cannot open config: " + path);
		}
		std::string section;
		std::string line;
		while (std::getline(in, line)) {
			auto pos = line.find('#');
			if (pos != std::string::npos)
				line = line.substr(0, pos);
			line = trim(line);
			if (line.empty())
				continue;
			if (line.front() == '[' && line.back() == ']') {
				section = trim(line.substr(1, line.size() - 2));
				continue;
			}
			auto eq = line.find('=');
			if (eq == std::string::npos)
				continue;
			std::string key = trim(line.substr(0, eq));
			std::string val = trim(line.substr(eq + 1));
			if (!section.empty())
				key = section + "." + key;
			cfg.kv[key] = val;
		}
		return cfg;
	}

	bool has(const std::string &key) const { return kv.count(key) > 0; }

	std::string get_str(const std::string &key,
			    const std::string &def) const
	{
		auto it = kv.find(key);
		return it == kv.end() ? def : it->second;
	}

	double get_double(const std::string &key, double def) const
	{
		auto it = kv.find(key);
		if (it == kv.end())
			return def;
		try {
			return std::stod(it->second);
		} catch (...) {
			return def;
		}
	}

	long get_long(const std::string &key, long def) const
	{
		auto it = kv.find(key);
		if (it == kv.end())
			return def;
		try {
			return std::stol(it->second);
		} catch (...) {
			return def;
		}
	}

	bool get_bool(const std::string &key, bool def) const
	{
		auto it = kv.find(key);
		if (it == kv.end())
			return def;
		std::string v = it->second;
		for (auto &c : v)
			c = (char)tolower(c);
		if (v == "1" || v == "true" || v == "yes" || v == "on")
			return true;
		if (v == "0" || v == "false" || v == "no" || v == "off")
			return false;
		return def;
	}

	std::vector<std::string> get_list(const std::string &key) const
	{
		auto it = kv.find(key);
		return it == kv.end() ? std::vector<std::string>{}
				      : split_list(it->second);
	}
};

struct DaemonSettings {
	std::vector<std::string> targets;
	std::vector<std::string> excludes;
	std::vector<std::string> bg;
	double alpha = 0.3;
	double wake_hi = 500.0;
	double run_lo_ns = 2000000.0;
	double delay_lo_ns = 500000.0;
	double ipc_hi = 1.2;
	double mpki_hi = 10.0;
	int hysteresis_cycles = 5;
	int interval_ms = 100;
	bool policy_enabled = true;
	bool classify_pmu = true;
	bool lat_moderate = true;
	bool llc_affinity = true;
	bool bg_contain = true;
	bool preempt = true;
	bool dry_run = false;
	int duration_s = 0;
	std::string log_dir = "logs";

	static DaemonSettings from_config(const Config &cfg)
	{
		DaemonSettings s;
		s.targets = cfg.get_list("targets.process_names");
		s.excludes = cfg.get_list("targets.exclude_names");
		s.bg = cfg.get_list("bg.process_names");
		s.alpha = cfg.get_double("classifier.alpha", s.alpha);
		s.wake_hi = cfg.get_double("classifier.wake_hi", s.wake_hi);
		s.run_lo_ns = cfg.get_double("classifier.run_lo_ns", s.run_lo_ns);
		s.delay_lo_ns = cfg.get_double("classifier.delay_lo_ns", s.delay_lo_ns);
		s.ipc_hi = cfg.get_double("classifier.ipc_hi", s.ipc_hi);
		s.mpki_hi = cfg.get_double("classifier.mpki_hi", s.mpki_hi);
		s.hysteresis_cycles =
			(int)cfg.get_long("classifier.hysteresis_cycles",
					  s.hysteresis_cycles);
		s.interval_ms = (int)cfg.get_long("policy.interval_ms", s.interval_ms);
		s.policy_enabled = cfg.get_bool("policy.adaptive", s.policy_enabled);
		s.classify_pmu = cfg.get_bool("policy.classify_pmu", s.classify_pmu);
		s.lat_moderate = cfg.get_bool("classifier.lat_moderate", s.lat_moderate);
		s.llc_affinity = cfg.get_bool("policy.llc_affinity", s.llc_affinity);
		s.bg_contain = cfg.get_bool("policy.bg_contain", s.bg_contain);
		s.preempt = cfg.get_bool("policy.preempt", s.preempt);
		s.log_dir = cfg.get_str("log.dir", s.log_dir);
		if (s.interval_ms < 10)
			s.interval_ms = 10;
		return s;
	}
};

} // namespace sp
