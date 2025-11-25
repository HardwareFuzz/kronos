ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD := $(ROOT)/build

RISCV32_PREFIX ?= riscv32-unknown-elf-
RISCV64_PREFIX ?= riscv64-unknown-elf-

# Pick available toolchain
ifeq (,$(shell which $(RISCV32_PREFIX)gcc 2>/dev/null))
RISCV_PREFIX := $(RISCV64_PREFIX)
else
RISCV_PREFIX := $(RISCV32_PREFIX)
endif

CC      := $(RISCV_PREFIX)gcc
OBJDUMP := $(RISCV_PREFIX)objdump
OBJCOPY := $(RISCV_PREFIX)objcopy
NM      := $(RISCV_PREFIX)nm

CFLAGS := -Os -march=rv32i_zicsr_zifencei -mabi=ilp32 -nostartfiles -static -ffreestanding -fno-builtin
LDFLAGS := -T $(ROOT)/skiptrap.ld

TARGET := $(BUILD)/skiptrap

all: $(TARGET).elf $(TARGET).bin $(TARGET).objdump $(TARGET).nm

$(BUILD):
	@mkdir -p $(BUILD)

$(TARGET).elf: $(BUILD) $(ROOT)/skiptrap.S $(ROOT)/skiptrap.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(ROOT)/skiptrap.S -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).objdump: $(TARGET).elf
	$(OBJDUMP) -D $< > $@

$(TARGET).nm: $(TARGET).elf
	$(NM) $< > $@

.PHONY: clean
clean:
	@rm -rf $(BUILD)

