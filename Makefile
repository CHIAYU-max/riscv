# make test      build riscv-tests (rv32ui) and run them on rv32i_core (Icarus Verilog)
# make test-one T=add [VCD=1]   run one test; VCD=1 writes build/add.vcd
# make selftest  check the testbench with a stand-in core (needs only iverilog)
# make c-test    build the C programs in sw/c/programs and run them on rv32i_core
# make c-one P=fib [VCD=1]      run one C program
# make trace T=add | P=fib [RETIRE=1]   run the core and the golden model (sw/iss.py) and compare
#                stores; RETIRE=1 also compares every retired instruction (needs the retire_* ports)
# make iss-test  run all tests and C programs on the golden model alone (checks sw/iss.py)
# make dot4-iss  run the dot4 test and both convolution benchmarks on the golden model (--dot4)
# make dot4-test run the dot4 test and conv_dot4 on rv32i_core (needs dot4 in the RTL)
# make bench     cycles (core) and instructions (golden model) for conv_ref vs conv_dot4
# make bit P=demo [MHZ=25]      Vivado bitstream for Basys3 with program P in memory
#                (source Vivado's settings64.sh first; output in build/fpga/)
# make fmax P=demo [FMAX_MHZ=50] [CORE=...]   place and route on Basys3, report Fmax and the core's
#                LUT / FF / DSP (no bitstream; source settings64.sh first; output in build/fmax/)
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

# CORE overrides the core sources, e.g. CORE=tb/selftest_core.v to check the script without rv32i_core.v
CORE ?= $(CORE_RTL)
FMAX_MHZ ?= 50
fmax: build/c/$(P).hex
	$(VIVADO) -mode batch -nojournal -log build/fmax.log -source fpga/fmax.tcl \
	    -tclargs build/c/$(P).hex $(FMAX_MHZ) $(CORE) | grep FMAX_DONE

test-one: build/sim_core build/tests/$(T).hex
	vvp -n build/sim_core +HEX=build/tests/$(T).hex +NAME=$(T) $(if $(VCD),+VCD)

TRACE_NAME = $(or $(T),$(P))
TRACE_HEX  = $(if $(T),build/tests/$(T).hex,build/c/$(P).hex)
TRACE_SIM  = $(if $(RETIRE),build/sim_core_retire,build/sim_core)

# The simulator and the golden model may both report FAIL; the comparison decides
trace: $(TRACE_SIM) $(TRACE_HEX)
	mkdir -p build/trace
	-vvp -n $(TRACE_SIM) +HEX=$(TRACE_HEX) +NAME=$(TRACE_NAME) +TRACE=build/trace/$(TRACE_NAME).core $(if $(VCD),+VCD)
	-python3 sw/iss.py $(TRACE_HEX) --trace build/trace/$(TRACE_NAME).ref
	python3 sw/trace_diff.py build/trace/$(TRACE_NAME).ref build/trace/$(TRACE_NAME).core --dump $(TRACE_HEX:.hex=.dump)

iss-test: $(TEST_HEX) $(C_HEX)
	@fail=0; for hex in $^; do python3 sw/iss.py $$hex || fail=1; done; exit $$fail

tests: $(TEST_HEX)

# dot4 custom instruction (README "dot4 custom instruction"). Kept out of c-test: a core
# without dot4 must still pass everything else. dot4 is u8 x s8; DOT4_ACT=signed builds the
# programs for s8 x s8 instead (also set DOT4_RS1_SIGNED = True in sw/iss.py).
DOT4_HEX    := build/c/dot4_test.hex build/c/conv_ref.hex build/c/conv_dot4.hex
BENCH_STEPS ?= 3000000
DOT4_ACT    ?= unsigned

build/c/conv_data.h: sw/c/gen_conv.py
	mkdir -p build/c
	python3 $< --out $@ $(if $(filter unsigned,$(DOT4_ACT)),--unsigned-act)

build/c/dot4_test.elf: sw/c/bench/dot4_test.c sw/c/dot4.h sw/c/crt0.S sw/c/link.ld
	mkdir -p build/c
	$(CC) $(C_CFLAGS) $(if $(filter signed,$(DOT4_ACT)),-DDOT4_RS1_SIGNED=1) sw/c/crt0.S $< -lgcc -o $@

build/c/conv_ref.elf: sw/c/bench/conv.c build/c/conv_data.h sw/c/crt0.S sw/c/link.ld
	$(CC) $(C_CFLAGS) -Ibuild/c sw/c/crt0.S $< -lgcc -o $@

# Baseline with a hardware multiplier (RV32IM, mul only): golden model only, rv32i_core has no M extension
build/c/conv_mul.elf: sw/c/bench/conv.c build/c/conv_data.h sw/c/crt0.S sw/c/link.ld
	$(CC) $(subst -march=rv32i ,-march=rv32im ,$(C_CFLAGS)) -Ibuild/c sw/c/crt0.S $< -lgcc -o $@

build/c/conv_dot4.elf: sw/c/bench/conv.c build/c/conv_data.h sw/c/dot4.h sw/c/crt0.S sw/c/link.ld
	$(CC) $(C_CFLAGS) -Ibuild/c -DUSE_DOT4 sw/c/crt0.S $< -lgcc -o $@

dot4-iss: $(DOT4_HEX)
	@fail=0; for hex in $^; do python3 sw/iss.py --dot4 --max-steps $(BENCH_STEPS) $$hex || fail=1; done; exit $$fail

dot4-test: build/sim_core build/c/dot4_test.hex build/c/conv_dot4.hex
	sw/run_tests.sh build/sim_core build/c/dot4_test.hex build/c/conv_dot4.hex

bench: build/sim_core build/c/conv_ref.hex build/c/conv_mul.hex build/c/conv_dot4.hex
	@python3 sw/iss.py --mul --max-steps $(BENCH_STEPS) build/c/conv_mul.hex
	@for p in conv_ref conv_dot4; do \
	    vvp -n build/sim_core +HEX=build/c/$$p.hex +NAME=$$p +MAX_CYCLES=$(BENCH_STEPS) | grep -E '^(PASS|FAIL|TIMEOUT|BADADDR|ERROR)'; \
	    python3 sw/iss.py --dot4 --max-steps $(BENCH_STEPS) build/c/$$p.hex; \
	done

build/sim_core: tb/tb_core.v $(CORE_RTL)
	mkdir -p build
	iverilog -g2012 -Wall -s tb_core -o $@ tb/tb_core.v $(CORE_RTL)

build/sim_core_retire: tb/tb_core.v $(CORE_RTL)
	mkdir -p build
	iverilog -g2012 -Wall -DRETIRE_TRACE -s tb_core -o $@ tb/tb_core.v $(CORE_RTL)

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

.PHONY: test test-one tests c-test c-one trace iss-test dot4-iss dot4-test bench bit fmax selftest xsim sim clean
.PRECIOUS: build/tests/%.elf build/c/%.elf
