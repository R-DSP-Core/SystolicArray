ROOT_DIR := $(abspath ../..)
BUILD_DIR := $(ROOT_DIR)/build/verilator
TOP := cv32e40x_verilator_top
FLIST := tb/verilator/cv32e40x_verilator.flist
CPP_DRIVER := tb/verilator/sim_main.cpp
VERILATOR ?= verilator
PROGRAM ?= hello
PROGRAMS := hello arithmetic memory matmul npu_full
PROGRAM_DIR := $(ROOT_DIR)/test_program
PROGRAM_HEX := $(PROGRAM_DIR)/bin/$(PROGRAM).hex

VERILATOR_FLAGS := \
	--cc \
	--exe $(CPP_DRIVER) \
	--build \
	-j 0 \
	-Wno-fatal \
	-Wno-BLKANDNBLK \
	-Wno-COMBDLY \
	-Wno-IMPLICIT \
	-Wno-UNOPTFLAT \
	-Wno-WIDTHEXPAND \
	-Wno-WIDTHTRUNC \
	-DCOREV_ASSERT_OFF \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	-f $(FLIST)

.PHONY: all help build run trace program run-program trace-program run-all-programs list-programs clean

all: run

help:
	@echo "CV32E40X Verilator targets:"
	@echo "  run                         Run the built-in assembly smoke test"
	@echo "  trace                       Run the smoke test and write a VCD"
	@echo "  run-program PROGRAM=name    Build and run one bare-metal C program"
	@echo "  trace-program PROGRAM=name  Run one C program and write a VCD"
	@echo "  run-all-programs            Build and run all C programs"
	@echo "  list-programs               List available C programs"
	@echo "  clean                       Remove generated files"

build:
	mkdir -p $(BUILD_DIR)
	cd $(ROOT_DIR) && $(VERILATOR) $(VERILATOR_FLAGS)

run: build
	cd $(ROOT_DIR) && $(BUILD_DIR)/V$(TOP)

trace: VERILATOR_FLAGS += --trace
trace: build
	cd $(ROOT_DIR) && $(BUILD_DIR)/V$(TOP) +trace

program:
	$(MAKE) -C $(PROGRAM_DIR) PROGRAM=$(PROGRAM) all

run-program: build program
	cd $(ROOT_DIR) && $(BUILD_DIR)/V$(TOP) +firmware=$(PROGRAM_HEX)

trace-program: VERILATOR_FLAGS += --trace
trace-program: build program
	cd $(ROOT_DIR) && $(BUILD_DIR)/V$(TOP) +firmware=$(PROGRAM_HEX) +trace

run-all-programs: build
	@set -e; \
	for program in $(PROGRAMS); do \
		$(MAKE) program PROGRAM=$$program; \
		$(BUILD_DIR)/V$(TOP) +firmware=$(PROGRAM_DIR)/bin/$$program.hex; \
	done

list-programs:
	@echo $(PROGRAMS)

clean:
	$(MAKE) -C $(PROGRAM_DIR) clean
	rm -rf $(BUILD_DIR)
