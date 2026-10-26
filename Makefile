# make test      build riscv-tests (rv32ui) and run them on rv32i_core (Icarus Verilog)
# make test-one T=add [VCD=1]   run one test; VCD=1 writes build/add.vcd
# make selftest  check the testbench with a stand-in core (needs only iverilog)
# make c-test    build the C programs in sw/c/programs and run them on rv32i_core
# make c-one P=fib [VCD=1]      run one C program
# make bit P=demo [MHZ=25]      Vivado bitstream for Basys3 with program P in memory
#                (source Vivado's settings64.sh first; output in build/fpga/)
# make xsim     top_processor demo, Vivado simulator (source Vivado's settings64.sh first)
# make sim       top_processor demo, Icarus Verilog
# Tools (WSL): sudo apt install iverilog gcc-riscv64-unknown-elf

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
CFLAGS  := -march=rv32i -mabi=ilp32 -static -nostdlib -nostartfiles -T sw/env/link.ld

ISA_DIR := third_party/riscv-tests/isa
# Not included: fence_i (self-modifying code; a pipelined core needs to flush for it)
# and ma_data (misaligned accesses, which RV32I may trap on instead of supporting).
RV32UI ?= simple add addi and andi auipc beq bge bgeu blt bltu bne jal jalr \
          lb lbu lh lhu lw lui or ori sb sh sw sll slli slt slti sltiu sltu \
          sra srai srl srli sub xor xori ld_st st_ld
TEST_HEX := $(addprefix build/tests/,$(addsuffix .hex,$(RV32UI)))

# Core sources: everything in rtl/ except the top_processor demo
CORE_RTL := $(filter-out rtl/top_processor.v,$(wildcard rtl/*.v))

# top_processor demo
DEMO_RTL := $(wildcard rtl/*.v)
DEMO_TB  := tb/tb_reg32x32.v
DEMO_TOP := tb_top_processor

# C programs (sw/c): crt0 + libgcc for multiply / divide; main's return value goes to TOHOST
C_CFLAGS := -march=rv32i -mabi=ilp32 -O2 -ffreestanding -nostdlib -nostartfiles -T sw/c/link.ld -Wl,--no-warn-rwx-segments
C_PROGS  ?= sum fib sort muldiv
C_HEX    := $(addprefix build/c/,$(addsuffix .hex,$(C_PROGS)))
MHZ      ?= 25
VIVADO   ?= vivado

test: build/sim_core $(TEST_HEX)
	sw/run_tests.sh build/sim_core $(TEST_HEX)

c-test: build/sim_core $(C_HEX)
	sw/run_tests.sh build/sim_core $(C_HEX)

c-one: build/sim_core build/c/$(P).hex
	vvp -n build/sim_core +HEX=build/c/$(P).hex +NAME=$(P) $(if $(VCD),+VCD)

build/c/%.elf: sw/c/programs/%.c sw/c/crt0.S sw/c/link.ld sw/c/mmio.h
	mkdir -p build/c
	$(CC) $(C_CFLAGS) sw/c/crt0.S $< -lgcc -o $@

build/c/%.hex: build/c/%.elf
	$(OBJCOPY) -O binary $< $(@:.hex=.bin)
	python3 sw/bin2hex.py $(@:.hex=.bin) $@
	$(OBJDUMP) -d $< > $(@:.hex=.dump)

bit: build/c/$(P).hex
	$(VIVADO) -mode batch -nojournal -log build/fpga_build.log -source fpga/build.tcl \
	    -tclargs build/c/$(P).hex $(MHZ) $(CORE_RTL)

test-one: build/sim_core build/tests/$(T).hex
	vvp -n build/sim_core +HEX=build/tests/$(T).hex +NAME=$(T) $(if $(VCD),+VCD)

tests: $(TEST_HEX)

build/sim_core: tb/tb_core.v $(CORE_RTL)
	mkdir -p build
	iverilog -g2012 -Wall -s tb_core -o $@ tb/tb_core.v $(CORE_RTL)

build/tests/%.elf: $(ISA_DIR)/rv32ui/%.S sw/env/riscv_test.h sw/env/link.ld
	mkdir -p build/tests
	$(CC) $(CFLAGS) -Isw/env -I$(ISA_DIR)/macros/scalar $< -o $@

build/tests/%.hex: build/tests/%.elf
	$(OBJCOPY) -O binary $< $(@:.hex=.bin)
	python3 sw/bin2hex.py $(@:.hex=.bin) $@
	$(OBJDUMP) -d $< > $(@:.hex=.dump)

selftest:
	mkdir -p build
	iverilog -g2012 -Wall -s tb_core -o build/sim_selftest tb/tb_core.v tb/selftest_core.v
	sw/run_tests.sh build/sim_selftest tb/selftest.hex

xsim:
	mkdir -p build && cp tb/init.dat build/
	cd build && xvlog $(addprefix ../,$(DEMO_RTL) $(DEMO_TB)) && xelab -debug typical $(DEMO_TOP) -s sim && xsim sim -runall

sim:
	mkdir -p build && cp tb/init.dat build/
	iverilog -g2012 -o build/sim $(DEMO_RTL) $(DEMO_TB)
	cd build && vvp sim

clean:
	rm -rf build

.PHONY: test test-one tests c-test c-one bit selftest xsim sim clean
.PRECIOUS: build/tests/%.elf build/c/%.elf
