PROGRAM ?= hello
BIN_DIR ?= bin
WORK_DIR ?= ../build/test_program

SUPPORTED_PROGRAMS := hello arithmetic memory matmul npu_full
SOURCE_DIR := src
PROGRAM_SOURCE := $(SOURCE_DIR)/$(PROGRAM).c
ELF := $(WORK_DIR)/$(PROGRAM).elf
BIN := $(BIN_DIR)/$(PROGRAM).bin
HEX := $(BIN_DIR)/$(PROGRAM).hex
DIS := $(BIN_DIR)/$(PROGRAM).dis

ifneq ($(CROSS_COMPILE),)
CC := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump
TARGET_FLAGS :=
LINK_TARGET_FLAGS :=
else
RISCV_GCC := $(shell command -v riscv64-unknown-elf-gcc 2>/dev/null || command -v riscv32-unknown-elf-gcc 2>/dev/null)
ifneq ($(RISCV_GCC),)
CC := $(RISCV_GCC)
TOOL_PREFIX := $(patsubst %gcc,%,$(RISCV_GCC))
OBJCOPY := $(TOOL_PREFIX)objcopy
OBJDUMP := $(TOOL_PREFIX)objdump
TARGET_FLAGS :=
LINK_TARGET_FLAGS :=
else
CC := clang
OBJCOPY := llvm-objcopy
OBJDUMP := llvm-objdump
TARGET_FLAGS := --target=riscv32-unknown-elf
LINK_TARGET_FLAGS := --target=riscv32-unknown-elf -fuse-ld=lld
endif
endif

ARCH_FLAGS := -march=rv32im_zicsr -mabi=ilp32
CPPFLAGS := -I$(SOURCE_DIR)
CFLAGS := $(TARGET_FLAGS) $(ARCH_FLAGS) -O2 -g -ffreestanding -fno-builtin \
	-fno-stack-protector -fdata-sections -ffunction-sections -Wall -Wextra
ASFLAGS := $(TARGET_FLAGS) $(ARCH_FLAGS) -g
LDFLAGS := $(LINK_TARGET_FLAGS) $(ARCH_FLAGS) -nostdlib -Wl,-T,$(SOURCE_DIR)/link.ld \
	-Wl,--gc-sections -Wl,--no-relax

OBJECTS := $(WORK_DIR)/crt0.o $(WORK_DIR)/runtime.o $(WORK_DIR)/$(PROGRAM).o

.PHONY: all check-program clean

all: check-program $(HEX) $(DIS)

check-program:
	@case " $(SUPPORTED_PROGRAMS) " in \
		*" $(PROGRAM) "*) ;; \
		*) echo "Unknown PROGRAM=$(PROGRAM). Supported: $(SUPPORTED_PROGRAMS)"; exit 2 ;; \
	esac

$(BIN_DIR) $(WORK_DIR):
	mkdir -p $@

$(WORK_DIR)/crt0.o: $(SOURCE_DIR)/crt0.S | $(WORK_DIR)
	$(CC) $(CPPFLAGS) $(ASFLAGS) -c $< -o $@

$(WORK_DIR)/runtime.o: $(SOURCE_DIR)/runtime.c $(SOURCE_DIR)/runtime.h | $(WORK_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(WORK_DIR)/$(PROGRAM).o: $(PROGRAM_SOURCE) $(SOURCE_DIR)/runtime.h | $(WORK_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJECTS) $(SOURCE_DIR)/link.ld
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@

$(BIN): $(ELF) | $(BIN_DIR)
	$(OBJCOPY) -O binary $< $@

$(HEX): $(BIN)
	od -An -v -tx4 $< > $@

$(DIS): $(ELF) | $(BIN_DIR)
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -f $(BIN_DIR)/*.bin $(BIN_DIR)/*.hex $(BIN_DIR)/*.dis \
		$(BIN_DIR)/*.o $(BIN_DIR)/*.elf $(BIN_DIR)/*.map
	rm -rf $(WORK_DIR)
