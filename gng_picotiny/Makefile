
PYTHON_NAME ?= /mingw64/bin/python

RISCV_NAME 	?= riscv-none-elf
RISCV_PATH 	?= C:/xpack-riscv-none-elf-gcc-15.2.0-1
MAKE		?= make

FW_FILE 	 = fw/fw-flash/build/fw-flash.v

PROG_FILE	?= $(FW_FILE)
COMx	 	?= COM1

export PYTHON_NAME
export RISCV_NAME
export RISCV_PATH


.PHONY: all brom flash clean program

all: brom flash

$(FW_FILE): flash

brom:
	$(MAKE) -C fw/fw-brom

flash:
	$(MAKE) -C fw/fw-flash

clean:
	$(MAKE) -C fw/fw-brom clean
	$(MAKE) -C fw/fw-flash clean

program: $(PROG_FILE)
	$(PYTHON_NAME) sw/pico-programmer.py $(PROG_FILE) $(COMx)
