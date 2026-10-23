# make xsim   Vivado simulator (source Vivado's settings64.sh first)
# make sim    Icarus Verilog (WSL: sudo apt install iverilog)
RTL := $(wildcard rtl/*.v)
TB  := tb/tb_reg32x32.v
TOP := tb_top_processor

xsim:
	mkdir -p build && cp tb/init.dat build/
	cd build && xvlog $(addprefix ../,$(RTL) $(TB)) && xelab -debug typical $(TOP) -s sim && xsim sim -runall

sim:
	mkdir -p build && cp tb/init.dat build/
	iverilog -g2012 -o build/sim $(RTL) $(TB)
	cd build && vvp sim

clean:
	rm -rf build

.PHONY: xsim sim clean
