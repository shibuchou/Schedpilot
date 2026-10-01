// SPDX-License-Identifier: MIT
#pragma once

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <string>

namespace sp {

enum class LogLevel { Debug = 0, Info = 1, Warn = 2, Error = 3 };

inline bool &log_verbose()
{
	static bool v = false;
	return v;
}

inline void set_verbose(bool v)
{
	log_verbose() = v;
}

inline const char *level_name(LogLevel lvl)
{
	switch (lvl) {
	case LogLevel::Debug:
		return "DEBUG";
	case LogLevel::Info:
		return "INFO";
	case LogLevel::Warn:
		return "WARN";
	default:
		return "ERROR";
	}
}

inline void log(LogLevel lvl, const char *fmt, ...)
{
	if (lvl == LogLevel::Debug && !log_verbose())
		return;

	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	struct tm tm;
	localtime_r(&ts.tv_sec, &tm);
	char stamp[32];
	strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);

	fprintf(stderr, "[%s.%03ld][%s] ", stamp, ts.tv_nsec / 1000000,
		level_name(lvl));
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
}

inline uint64_t now_mono_ns()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL +
	       static_cast<uint64_t>(ts.tv_nsec);
}

inline uint64_t now_real_ns()
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL +
	       static_cast<uint64_t>(ts.tv_nsec);
}

inline std::string json_escape(const std::string &in)
{
	std::string out;
	out.reserve(in.size() + 8);
	for (char c : in) {
		switch (c) {
		case '"':
			out += "\\\"";
			break;
		case '\\':
			out += "\\\\";
			break;
		case '\n':
			out += "\\n";
			break;
		case '\r':
			out += "\\r";
			break;
		case '\t':
			out += "\\t";
			break;
		default:
			if (static_cast<unsigned char>(c) < 0x20) {
				char buf[8];
				snprintf(buf, sizeof(buf), "\\u%04x", c);
				out += buf;
			} else {
				out += c;
			}
		}
	}
	return out;
}

} // namespace sp
