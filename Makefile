# make test      build riscv-tests (rv32ui) and run them on rv32i_core (Icarus Verilog)
# make test-one T=add [VCD=1]   run one test; VCD=1 writes build/add.vcd
# make selftest  check the testbench with a stand-in core (needs only iverilog)
# make xsim      top_processor demo, Vivado simulator (source Vivado's settings64.sh first)
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

test: build/sim_core $(TEST_HEX)
	sw/run_tests.sh build/sim_core $(TEST_HEX)

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

.PHONY: test test-one tests selftest xsim sim clean
.PRECIOUS: build/tests/%.elf
