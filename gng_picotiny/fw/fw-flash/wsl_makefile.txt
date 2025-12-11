PROJ_NAME=fw-flash
DEBUG=no
BENCH=no
MULDIV=no
COMPRESSED=no

SRCS =  $(wildcard *.c) \
        $(wildcard *.S)

LDSCRIPT = ./linker_flash.ld

# ===========================================================
# FIXED FOR WSL - USE BUILT-IN RISCV GCC
# ===========================================================
RISCV_PREFIX = riscv64-unknown-elf-

RISCV_CC      = $(RISCV_PREFIX)gcc
RISCV_OBJCOPY = $(RISCV_PREFIX)objcopy
RISCV_OBJDUMP = $(RISCV_PREFIX)objdump

# Config
MABI=ilp32
MARCH := rv32i

ifeq ($(MULDIV),yes)
    MARCH := $(MARCH)m
endif

ifeq ($(COMPRESSED),yes)
    MARCH := $(MARCH)ac
endif

CFLAGS += -march=$(MARCH) -mabi=$(MABI) -ffunction-sections -fdata-sections
LDFLAGS += -march=$(MARCH) -mabi=$(MABI) -Wl,--gc-sections

ifeq ($(DEBUG),yes)
    CFLAGS += -g3 -O0
endif

ifeq ($(DEBUG),no)
    CFLAGS += -g -O3
endif

ifeq ($(BENCH),yes)
    CFLAGS += -fno-inline
endif

CFLAGS += -MD -fstrict-volatile-bitfields
LDFLAGS += -nostdlib -lgcc -mcmodel=medany -nostartfiles -ffreestanding \
           -Wl,-Bstatic,-T,$(LDSCRIPT),-Map,$(OBJDIR)/$(PROJ_NAME).map,--print-memory-usage

OBJDIR = build
OBJS := $(SRCS)
OBJS := $(OBJS:.c=.o)
OBJS := $(OBJS:.cpp=.o)
OBJS := $(OBJS:.S=.o)
OBJS := $(addprefix $(OBJDIR)/,$(OBJS))

# ===========================================================
# Build all: ELF + BIN + HEX
# ===========================================================
all: $(OBJDIR)/$(PROJ_NAME).elf \
     $(OBJDIR)/$(PROJ_NAME).bin \
     $(OBJDIR)/$(PROJ_NAME).hex

# ===========================================================
# LINK → ELF
# ===========================================================
$(OBJDIR)/%.elf: $(OBJS) | $(OBJDIR)
	$(RISCV_CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# ===========================================================
# ELF → BIN
# ===========================================================
$(OBJDIR)/%.bin: $(OBJDIR)/%.elf
	$(RISCV_OBJCOPY) -O binary $< $@

# ===========================================================
# ELF → HEX (VERILOG 8-BIT FORMAT)
# ===========================================================
$(OBJDIR)/%.hex: $(OBJDIR)/%.elf
	$(RISCV_OBJCOPY) -O verilog $< $@

# ===========================================================
# COMPILE C / ASM
# ===========================================================
$(OBJDIR)/%.o: %.c
	mkdir -p $(dir $@)
	$(RISCV_CC) -c $(CFLAGS) $(INC) -o $@ $<

$(OBJDIR)/%.o: %.S
	mkdir -p $(dir $@)
	$(RISCV_CC) -c $(CFLAGS) -o $@ $< -D__ASSEMBLY__=1

$(OBJDIR):
	mkdir -p $@

# ===========================================================
# CLEAN
# ===========================================================
clean:
	rm -rf $(OBJDIR)

.SECONDARY:
