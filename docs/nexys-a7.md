# Boards: Nexys A7-100T (main), Basys3 (build only), ZedBoard (planned)

Written 2026-11-20 when a Nexys A7-100T was borrowed; revised 2026-11-21 when it turned out the Nexys A7 can be
kept for as long as needed, the Basys3 cannot be borrowed for long, and a ZedBoard can be borrowed long-term in one
or two weeks.

## Which board does what

| Board | Role | Why |
| --- | --- | --- |
| **Nexys A7-100T** | **main board** for the core, the custom instructions and the demo (through the 12/27 README) | always available; standalone (no host needed), and the build and board flow already work |
| Basys3 | build only: one extra column of LUT / FF / DSP / Fmax, marked "synthesis and place and route, not run on the board" | cannot be borrowed for long; area and Fmax need no board, and a small part makes the "fits a small FPGA" point for the instruction-extension approach |
| ZedBoard (Zynq-7020) | planned main board for the accelerator work from 2/20 (coupling comparison, coprocessor, hls4ml, whole layers from DRAM); confirm after a first bring-up session | ARM host and DRAM through the PS (below) |

Every published number names its board; numbers from different boards go in separate columns, never in one number.

What was decided for the Nexys A7 (2026-11-20, unchanged by the 11/21 revision except where noted):

| Item | Decision | Why |
| --- | --- | --- |
| Port the design (top level, pins, build) | done | checked on the board with the stand-in core (Results) |
| Core memory 32 KiB | **default since 2026-11-21** (`MEM_KIB=32`, `sw/c/link.ld` 32K) | the INT8 tile with CIN 64 / COUT 8 does not fit in 8 KiB (design notes, "INT4 experiment"); all core numbers are measured fresh anyway, so nothing has to stay at 8 KiB |
| hls4ml `io_stream`, the whole `head.0.block.3` layer (32 of 32 output channels) | do (after the core), now also on the board | removes one extrapolation (8 -> 32 channels) from the cost model; also answers whether forcing DSPs (`config_op mul -impl dsp`) still fits (2020.2 used 75 DSP for 8 channels, so about 300 for 32, over the 240 on this part) |
| hls4ml `io_parallel` rf 8 / 32 / 144 / 288 | not done | they fit (26k-52k LUT) but miss 10 ns and are no faster than `io_stream` (rf 32: 677-2,965 vs 1,487 cycles) for 2.4x the LUTs |
| hls4ml `io_parallel` rf 1 | not done | 102,755 LUT (2:4: 70,924), still over the 63,400 LUTs |
| Block RAM for a larger memory | not done | BRAM reads are synchronous; the core interface (combinational reads) would change. The reason is the core interface, not the board |
| DDR2 through MIG | not done | a single-cycle core cannot use DRAM without a cache or DMA; DRAM work goes to the ZedBoard |

## Board differences

Pins and I/O standards are from Digilent's `Nexys-A7-100T-Master.xdc` (github.com/Digilent/digilent-xdc,
checked 2026-11-20); part resources from the Xilinx 7 series overview (DS180).

| | Basys3 | Nexys A7-100T |
| --- | --- | --- |
| Part | XC7A35T-1CPG236C | XC7A100T-1CSG324C |
| LUT / FF | 20,800 / 41,600 | 63,400 / 126,800 |
| DSP48E1 | 90 | 240 |
| Block RAM (36 Kb) | 50 | 135 |
| Distributed RAM | 400 Kb | 1,188 Kb |
| DRAM | none | 128 MiB DDR2 (not used) |
| Clock | 100 MHz, W5 | 100 MHz, E3 |
| Reset | BTNC, active high | CPU_RESETN (red button, C12), active low |
| Switches / LEDs | 16 / 16 | 16 / 16 (SW8, SW9 are LVCMOS18: bank 34 is 1.8 V) |
| 7-segment | 4 digits | 8 digits |
| USB-UART | yes | yes (FT2232: C4 = FPGA RX `uart_txd_in`, D4 = FPGA TX `uart_rxd_out`) |

## Structure

```
fpga/rtl/soc.v           board-independent: rv32i_core + fpga_mem + memory-mapped I/O (MEM_KIB parameter)
fpga/rtl/board_clk.v     MMCM 100 MHz -> CORE_MHZ, shared by both 100 MHz boards
fpga/rtl/seg7_hex.v      DIGITS = 4 or 8
fpga/rtl/nexys_a7_top.v  CPU_RESETN reset (inverted), 8 digits (seg_value[31:0])
fpga/rtl/basys3_top.v    BTNC reset, 4 digits (seg_value[15:0])
fpga/nexys_a7.xdc, fpga/basys3.xdc
fpga/boards.tcl          board -> part, JTAG device, top level, XDC; build.tcl, fmax.tcl and program.tcl read it
```

A board top level only does the clock, the reset synchronizer, the display and the pin mapping. Everything the
program can see (memory map, memory size, register behavior) is in `soc.v`, so it is the same on every board.
The core is instantiated as `u_soc/u_core`; `make fmax` counts the core's LUT / FF / DSP under that path.

## Compatibility rules

1. **Core interface**: unchanged (README "Core interface"). No board-specific code in `rtl/`.
2. **Memory map**: same addresses on every board. `SEG` and the TOHOST latch keep 32 bits; the Basys3 shows
   bits [15:0], the Nexys A7 all 32.
3. **The UART bridge / host interface (2/20)** uses one register table on every board; only the transport differs
   (UART on the Nexys A7, AXI-Lite from the ARM on the ZedBoard). The UART pins are already listed, commented out,
   in `fpga/nexys_a7.xdc`.
4. **Program images** link for 32 KiB (`sw/c/link.ld`) and run on the Nexys A7 and in simulation (64 KiB). The
   Basys3 build has 8 KiB and is not meant to run them.

## Memory size

`MEM_KIB` sets the RAM size in `soc.v`: 32 by default, 8 for `BOARD=basys3` (the Makefile picks it from the board).
The memory stays distributed RAM, because the core interface needs combinational reads; each read port keeps its
own copy, so 32 KiB uses 2 x 4,096 LUTs as RAM plus the read multiplexers: 9,355 LUTs measured (Results).

**What the larger memory costs, and how the core is measured anyway.** A 32 KiB read is about 2 ns slower than an
8 KiB one (Results), and a single-cycle core does two reads per cycle (instruction, then load). If the memory ends up
on the critical path, the board Fmax shows the memory, not the core, and the "with / without `dot4`" difference can
be hidden. So the core comparison reports, besides the board Fmax:

- the core's own paths, split around the two memory reads, as `asic/run_asic.sh` already does for the ASIC flow
  (the memories are outside the core there, so the ASIC numbers do not depend on `MEM_KIB` at all);
- one extra `make fmax MEM_KIB=8` run, to show how much of the board Fmax is the memory.

## Build and program

```bash
make bit prog P=demo                            # Nexys A7 (default), 32 KiB: build and program in one command
make fmax P=demo                                # build/fmax/nexys_a7/
make fmax P=demo MEM_KIB=8                      # memory-cost check (above)
make fmax P=demo BOARD=basys3                   # Basys3 column, 8 KiB, build only
```

Output goes to `build/fpga/<board>/` and `build/fmax/<board>/`. Before the core exists, check the board with the
stand-in core and the image it expects: `make bit prog CORE=tb/selftest_core.v HEX=tb/selftest.hex`. The display
shows the TOHOST value: `00000001` pass, `00000003` the memory image is not the expected one (word 0 must be
`0x00000013`; any other program, such as `demo`, gives 3), `00000005` byte-lane error.

**Programming from WSL.** Vivado runs in WSL, so the board's USB (FTDI `0403:6010`) has to be passed to WSL with
usbipd-win. Once per board, in an administrator PowerShell: `usbipd list` to find the bus id, then
`usbipd bind --busid <id>`. After that `make prog` attaches the board by itself when WSL cannot see it
(`fpga/attach_usb.sh` runs `usbipd.exe attach --wsl --hardware-id 0403:6010` from WSL; no administrator needed), and
the Makefile finds Vivado without sourcing `settings64.sh` (it falls back to `/Xilinx/2025.2.1/Vivado/bin/vivado`).
`make prog` fails with `PROGRAM_ERROR` if the FPGA on the cable is not the one `BOARD` names. The Digilent udev
rules from Vivado's `install_drivers` are already in WSL. `usbipd detach --hardware-id 0403:6010` (Windows) gives the
board back to Windows. The bitstream goes into the FPGA's configuration memory only: it is lost at power-off and the
flash is not touched.

## Acceptance

1. `make bit` builds for both boards with the stand-in core and with the real core, timing met at 25 MHz
   (stand-in core: done, and `00000001` on the Nexys A7, 2026-11-21).
2. `demo` on the Nexys A7: fib(`SW[4:0]`) on the display (8 digits, upper 4 zero), counter on the LEDs,
   CPU_RESETN restarts it.
3. Once the host interface exists: `block_nn` gives the same output and the same cycle count on the board and in
   simulation.
4. With the real core at 32 KiB: timing met at 25 MHz; board Fmax, the core's own paths and the `MEM_KIB=8` Fmax
   recorded here.
5. hls4ml whole layer: bit-exact in C simulation, co-simulation passes, out-of-context numbers on
   `xc7a100tcsg324-1` with and without forced DSPs, then (if it fits) on the board behind the stream interface.

## Results

2026-11-20 / 21, Vivado 2025.2.1 (WSL), no real core yet.

**Script check with the stand-in core** (`tb/selftest_core.v`, program `demo`): `make bit` passes for the Basys3
(the refactored `basys3_top`, WNS +33.6 ns at 25 MHz), the Nexys A7 with `MEM_KIB=8` and with `MEM_KIB=32`
(WNS +34.0 ns), no critical warnings.

**On the board (2026-11-21).** Nexys A7-100T, programmed from WSL with `make prog` (JTAG target found, device
`xc7a100t_0`). With `CORE=tb/selftest_core.v HEX=tb/selftest.hex` and `MEM_KIB=8`: the display shows `00000001`
(pass) on 8 digits and LED15 is on. This checks the clock and MMCM, the CPU_RESETN polarity, the memory image loaded
at configuration, byte-lane stores, the TOHOST latch, the LED pin and the 8-digit scan. A first try with the `demo`
image showed `00000003`, as expected (the stand-in core needs `tb/selftest.hex` at address 0). Switches, the other
15 LEDs and the 32 KiB memory on the board are checked once the real core runs `demo`. The refactored `basys3_top`
was not run on a Basys3 (build only, see "Which board does what").

**Memory cost.** The stand-in core reads only two addresses, so Vivado trims the memory to 128 LUTs. To measure the
whole memory, a throwaway core that sweeps both ports over every address (not in the repository) was run through
`make fmax` at 50 MHz:

| Board | `MEM_KIB` | `fpga_mem` LUTs | of which LUT as RAM | Share of the part | Fmax of the sweep core |
| --- | --- | ---: | ---: | --- | ---: |
| Basys3 | 8 | 2,320 | 2,048 | 11% of LUTs, 21% of LUT-RAM | 71.1 MHz |
| Nexys A7 | 8 | 2,320 | 2,048 | 4% of LUTs, 11% of LUT-RAM | 72.8 MHz |
| Nexys A7 | 32 | 9,355 | 8,192 | 15% of LUTs, 43% of LUT-RAM | 63.5 MHz |

- Each read port keeps its own copy (2 x 4,096 LUTs for 32 KiB), as expected; the rest is the read multiplexers.
- The larger memory makes a read about 2 ns slower (72.8 -> 63.5 MHz on a path that is one read). The real core
  reads twice per cycle (instruction, then load), so expect a larger drop; measure with the real core.
- On the Basys3, 32 KiB would take 85% of its 9,600 LUT-RAM LUTs, so 16 KiB is the practical limit there.

**Golden model with the 32 KiB link script (2026-11-21):** `make iss-test`, `make dot4-iss` and `make block-iss` pass;
`make selftest` passes.

## ZedBoard (planned, long-term loan expected late November / early December)

XC7Z020-1CLG484C (from DS190; recheck when the board is here). Its programmable logic has **fewer** LUTs and DSPs than
the Nexys A7, so it is not chosen for logic size:

| | Nexys A7-100T | ZedBoard PL (Zynq-7020) |
| --- | --- | --- |
| LUT / FF | 63,400 / 126,800 | 53,200 / 106,400 |
| DSP48E1 | 240 | 220 |
| Block RAM (36 Kb) | 135 | 140 |
| Host | none (UART to the PC) | dual Cortex-A9 in the PS |
| DRAM | 128 MiB DDR2, needs MIG in the logic | 512 MB DDR3 on the PS, reached through the HP AXI ports |

What it adds is the host and the DRAM path, which is what the accelerator work needs:

- **A host on the chip.** The ZynqParrot idea in the design notes (one host program for simulation and the board,
  clock gated while the host is slow) can be done as ZynqParrot does it: the ARM writes the register table over
  AXI-Lite instead of a UART, and loads weights and images without a UART bottleneck.
- **DRAM without MIG.** A coprocessor or the hls4ml design can stream whole layers from DDR3 through the HP ports,
  which is what "limited to small tiles" in the design notes was about.

Why the core and the custom instructions stay on the Nexys A7: what limited the instruction designs so far was the
instruction format and the core, not the FPGA size. `dot4` is four lanes because a register is 32 bits and an
R-type instruction reads two registers; the 2:4 `dot4` was dropped because it needs three or more source operands;
the core uses a few thousand LUTs of the 63,400. A bigger board does not lift these limits. What lifts them is
moving work out of the instruction stream into a coprocessor with its own buffers and its own path to memory,
which is the coupling comparison, and that is where the ZedBoard helps.

What the move costs: a block design with the `processing_system7` IP (PL clock and reset from the PS FCLK), a
separate build script (not just a row in `fpga/boards.tcl`), and an ARM program built with Vitis. `soc.v` stays as it
is. 8 switches, 8 LEDs, no 7-segment display (as far as I know; check the reference manual), so results are read by
the ARM. Fmax on the Zynq PL is a separate column.

Plan: no ZedBoard work before the 12/20 milestone. When the board is here, one bring-up session (PS + PL, the ARM
reads and writes one register in `soc.v`) decides whether the 2/20 sessions (register table, host interface, gated
cycle counter) are built on the ZedBoard with AXI-Lite instead of a UART on the Nexys A7.
