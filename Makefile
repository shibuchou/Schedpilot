# SchedPilot v0.3 provincial MVP - build
#
# Dev build (any Linux with clang/libbpf, kernel image may differ from target):
#   make            # builds BPF object, loader, daemon under build/
#   make vmlinux    # regenerate build/vmlinux.h from the running kernel BTF
#
# Target build on the frozen environment (openEuler 24.03 LTS SP4) uses the
# kernel's own tools/sched_ext tree via scripts/build.sh --kernel-src.

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR ?= $(ROOT)/build
SCX_INC ?= $(ROOT)/third_party/scx-dev/include
VMLINUX ?= $(BUILD_DIR)/vmlinux.h
CLANG ?= clang
CC ?= cc
CXX ?= g++

BPF_CFLAGS := -g -O2 -target bpf -mcpu=v3 -D__TARGET_ARCH_x86 -D__SCHEDPILOT_BPF__ \
	      -I$(SCX_INC) -I$(BUILD_DIR) -Wno-compare-distinct-pointer-types
CFLAGS := -O2 -g -Wall -Wextra -I$(ROOT)/bpf -I$(SCX_INC) -I$(BUILD_DIR)
CXXFLAGS := -O2 -g -std=c++17 -Wall -Wextra -I$(ROOT)/bpf -I$(BUILD_DIR)

DAEMON_SRCS := $(ROOT)/daemon/schedpilotd.cpp \
	       $(ROOT)/daemon/pmu_sampler.cpp \
	       $(ROOT)/daemon/classifier.cpp \
	       $(ROOT)/daemon/bpf_iface.cpp

.PHONY: all bpf loader daemon vmlinux clean check

all: bpf loader daemon

$(BUILD_DIR):
	mkdir -p $@

vmlinux: $(VMLINUX)
$(VMLINUX): | $(BUILD_DIR)
	@if [ -f "$(ROOT)/bpf/vmlinux.h" ]; then \
		echo "using vendored bpf/vmlinux.h"; \
		cp "$(ROOT)/bpf/vmlinux.h" $@; \
	else \
		echo "generating vmlinux.h from running kernel BTF"; \
		bpftool btf dump file /sys/kernel/btf/vmlinux format c > $@; \
	fi

bpf: $(BUILD_DIR)/scx_schedpilot.bpf.o
$(BUILD_DIR)/scx_schedpilot.bpf.o: $(ROOT)/bpf/scx_schedpilot.bpf.c \
		$(ROOT)/bpf/intf.h $(VMLINUX) | $(BUILD_DIR)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
	@echo "built $@"

$(BUILD_DIR)/scx_schedpilot.bpf.skel.h: $(BUILD_DIR)/scx_schedpilot.bpf.o
	bpftool gen skeleton $< name scx_schedpilot > $@
	@echo "built $@"

loader: $(BUILD_DIR)/scx_schedpilot
$(BUILD_DIR)/scx_schedpilot: $(ROOT)/loader/scx_schedpilot.c \
		$(BUILD_DIR)/scx_schedpilot.bpf.skel.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@ -lbpf -lelf -lz
	@echo "built $@"

daemon: $(BUILD_DIR)/schedpilotd
$(BUILD_DIR)/schedpilotd: $(DAEMON_SRCS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(DAEMON_SRCS) -o $@ -lbpf -lelf -lz
	@echo "built $@"

check:
	@bash -n $(ROOT)/scripts/*.sh $(ROOT)/bench/*.sh $(ROOT)/tests/*.sh && echo "shell syntax OK"
	@python3 -m py_compile $(ROOT)/bench/analyze_results.py \
		$(ROOT)/bench/parse_redis.py $(ROOT)/bench/parse_wrk.py \
		$(ROOT)/bench/parse_mysql.py $(ROOT)/bench/reparse_results.py \
		&& echo "python compile OK"
	@$(MAKE) --no-print-directory test

test: $(BUILD_DIR)/classifier_test
	$(BUILD_DIR)/classifier_test

$(BUILD_DIR)/classifier_test: $(ROOT)/tests/classifier_test.cpp \
		$(ROOT)/daemon/classifier.cpp | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I$(ROOT)/daemon $^ -o $@

clean:
	rm -rf $(BUILD_DIR)
