# Second board: Nexys A7-100T

Written 2026-11-20, when a Nexys A7-100T was borrowed. A ZedBoard may be borrowed later; its section is at the end.

## Purpose and scope

The **Basys3 stays the main board**: the README, the demo and every published number must be reproducible on it.
The Nexys A7 is a second target for results that do not fit on the Basys3, and nothing else. Work on it starts
after the core is done (11/30) and does not move any Basys3 date.

| Item | Decision | Why |
| --- | --- | --- |
| Port the design (top level, pins, build) | do now | needed for anything else; uses a stand-in core until the core is done |
| Core memory 8 KiB -> 32 KiB (`MEM_KIB=32`) | do (hardware now, software later) | the INT8 tile with CIN 64 / COUT 8 does not fit in 8 KiB (design notes, "INT4 experiment"); with 32 KiB INT8 and INT4 can run the same tile |
| hls4ml `io_stream`, the whole `head.0.block.3` layer (32 of 32 output channels) | do (after the core) | removes one extrapolation (8 -> 32 channels) from the cost model; also answers whether forcing DSPs (`config_op mul -impl dsp`) still fits (2020.2 used 75 DSP for 8 channels, so about 300 for 32, over the 240 on this part) |
| hls4ml `io_parallel` rf 8 / 32 / 144 / 288 | not done | they fit (26k-52k LUT) but miss 10 ns and are no faster than `io_stream` (rf 32: 677-2,965 vs 1,487 cycles) for 2.4x the LUTs |
| hls4ml `io_parallel` rf 1 | not done | 102,755 LUT (2:4: 70,924), still over the 63,400 LUTs |
| Block RAM for a larger memory | not done | BRAM reads are synchronous; the core interface (combinational reads) would change |
| DDR2 through MIG | not done (optional, later) | a single-cycle core cannot use DRAM without a cache or DMA |

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
fpga/rtl/basys3_top.v    BTNC reset, 4 digits (seg_value[15:0])
fpga/rtl/nexys_a7_top.v  CPU_RESETN reset (inverted), 8 digits (seg_value[31:0])
fpga/basys3.xdc, fpga/nexys_a7.xdc
fpga/boards.tcl          board -> part, top level, XDC; build.tcl and fmax.tcl read it
```

A board top level only does the clock, the reset synchronizer, the display and the pin mapping. Everything the
program can see (memory map, memory size, register behavior) is in `soc.v`, so it is the same on every board.
The core is instantiated as `u_soc/u_core`; `make fmax` counts the core's LUT / FF / DSP under that path.

## Compatibility rules

1. **Core interface**: unchanged (README "Core interface"). No board-specific code in `rtl/`.
2. **Memory map**: same addresses on both boards. `SEG` and the TOHOST latch now keep 32 bits; the Basys3 shows
   bits [15:0] as before, the Nexys A7 all 32. Programs that write 16-bit values behave the same on both.
3. **The UART bridge (2/20)** gets the same register addresses on every board. Its pins are already listed,
   commented out, in `fpga/nexys_a7.xdc`.
4. **Same program image**: with `MEM_KIB=8` (the default on both boards) the same `build/c/<P>.hex` runs on both,
   and the results must be bit-identical.
5. **Numbers name their board.** Fmax and LUT counts depend on the part and package, so Basys3 and Nexys A7 results
   go in separate columns, never in one number. The published comparison stays on the Basys3 where it fits.

## Memory size

`MEM_KIB` (8 or 32, a power of two) sets the RAM size in `soc.v`. The memory stays distributed RAM, because the core
interface needs combinational reads; each read port keeps its own copy, so 32 KiB uses about 2 x 4,096 LUTs as
RAM plus the read multiplexers: 9,355 LUTs measured (Results).

Software side, not done yet: C programs still link for 8 KiB (`sw/c/link.ld`), which runs unchanged in 32 KiB.
When a 32 KiB program is needed (the CIN 64 tile), the Makefile generates a linker script with `LENGTH = 32K` into
a separate build directory (for example `build/c_32k/`), so 8 KiB and 32 KiB images are never mixed. The simulation
RAM (64 KiB) is already large enough.

## Build

```bash
source /Xilinx/2025.2.1/Vivado/settings64.sh
make bit  P=demo BOARD=nexys_a7                 # build/fpga/nexys_a7/nexys_a7_top.bit
make bit  P=demo BOARD=nexys_a7 MEM_KIB=32
make fmax P=demo BOARD=nexys_a7                 # build/fmax/nexys_a7/
make bit  P=demo                                # Basys3, as before (output now in build/fpga/basys3/)
```

Before the core exists, add `CORE_RTL=tb/selftest_core.v` (`bit`) or `CORE=tb/selftest_core.v` (`fmax`) to check
the scripts. Program the board with the Vivado Hardware Manager, as for the Basys3.

## Acceptance

1. `make bit` builds for both boards with the stand-in core and with the real core, timing met at 25 MHz.
2. `demo` on the Nexys A7: fib(`SW[4:0]`) on the display (8 digits, upper 4 zero), counter on the LEDs,
   CPU_RESETN restarts it.
3. Once the UART bridge exists: `block_nn` gives the same output and the same cycle count on both boards and in
   simulation.
4. `MEM_KIB=32` with the real core: timing met at 25 MHz; LUT-as-RAM count recorded here.
5. hls4ml whole layer: bit-exact in C simulation, co-simulation passes, out-of-context numbers on
   `xc7a100tcsg324-1` with and without forced DSPs, then (if it fits) on the board behind the stream interface.

## Results

2026-11-20 / 21, Vivado 2025.2.1 (WSL), no real core yet.

**Script check with the stand-in core** (`tb/selftest_core.v`, program `demo`): `make bit` passes for the Basys3
(the refactored `basys3_top`, WNS +33.6 ns at 25 MHz), the Nexys A7 with `MEM_KIB=8` and with `MEM_KIB=32`
(WNS +34.0 ns), no critical warnings. Not yet checked on the board.

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

## Later: ZedBoard

A ZedBoard (Zynq-7020, XC7Z020-1CLG484C: 53,200 LUT, 106,400 FF, 220 DSP, 140 block RAMs, from DS190; recheck when the
board is here) may be borrowed later. What it changes:

- **It has ARM cores.** The ZynqParrot idea in the design notes (one host program for simulation and the board,
  clock gated while the host is slow) can then be done as ZynqParrot does it: the ARM writes the core's registers
  over AXI-Lite instead of a UART. The register table stays the same; only the bridge differs (UART on the
  Artix boards, AXI-Lite on the Zynq).
- **DRAM without MIG.** The PS has 512 MB DDR3; the PL reaches it through the HP AXI ports, so a DMA for a
  coprocessor is easier there than through MIG on the Nexys A7.
- **Different build.** The PL clock and reset come from the PS (FCLK), and the design needs a block design with the
  `processing_system7` IP: a separate script, not a row in `fpga/boards.tcl` alone. `soc.v` stays as it is.
- **Different I/O.** 8 switches, 8 LEDs, no 7-segment display (as far as I know; check the reference manual), so the
  board top level maps `led_o` and the result to what exists, and results are read by the ARM.
- Fmax on the Zynq PL is a separate column again (same fabric family, different part and package).

To decide when the board is here: whether the coupling comparison (custom instruction / coprocessor / hls4ml) moves
to the ZedBoard, since the ARM host makes the hls4ml and coprocessor runs much easier to drive.
