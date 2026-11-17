# ASIC flow (TSMC 0.13 µm)

`run_asic.sh` takes `rv32i_core` from RTL to a routed, signed-off layout and measures it on real programs. It reuses
the flow of an earlier project ([geofence-rtl-to-gdsii](https://github.com/CHIAYU-max/geofence-rtl-to-gdsii)):

| Step | Tool | Output |
| --- | --- | --- |
| Synthesis | Design Compiler (`compile_ultra -no_autoungroup`, hierarchy kept for the area breakdown) | `rpt/syn_area_hier.rpt` |
| Floorplan, power grid, placement, CTS, routing, fillers | IC Compiler II (`apr/01_init.tcl` … `03_out.tcl`) | netlist, SDF, SPEF, GDS in `out/` |
| STA | PrimeTime with the ICC2 SPEF: setup at the slow corner (1.08 V, 125 °C), hold at slow and fast (1.32 V, −40 °C) | `rpt/pt_*.rpt` |
| Post-layout simulation of each program | VCS, `tb/tb_core.v` with the ICC2 SDF, clock set to the target cycle | pass / fail, cycles, SAIF |
| Power and energy per program | PrimePower, averaged, with the program's SAIF | `rpt/pwr_<program>.rpt` |
| DRC, black-box LVS | IC Validator | `drc/`, `lvs/` |

```bash
# on the server, from the repository root (the programs are built in WSL first: make block-iss)
asic/run_asic.sh base 10 "rtl/rv_pkg.sv rtl/alu.sv rtl/decoder.sv rtl/pc_reg.sv rtl/reg32x32_2r.sv rtl/rv32i_core.sv" \
    build/c/block_ref.hex build/c/block_dot4.hex build/c/block_nn.hex build/c/block_rb.hex
```

Each program adds one line to `asic/runs/summary.csv`: area, slack at the three checks, the cycle split below, the
post-layout result and cycle count, power and energy. `DEFINES` passes Verilog defines (for example a core built with
and without `dot4`), `UTIL` sets the core utilization (default 0.6), `SKIP_SIGNOFF=1` skips DRC and LVS.

## The cycle and the external memories

The memories are outside the core and read combinationally (README "Core interface"), so in a single-cycle core
one instruction is one path: PC → `imem_addr` → instruction → `dmem_addr` → load data → register file. The core
alone cannot see that whole path, so `pt_io.sdc` gives the ports a budget with zero-delay memories: PC to
`imem_addr` 30% of the cycle, instruction to `dmem_addr` 30%, load data to the registers 40%. PrimeTime then
reports the four segments in `rpt/pt_segments.txt`, and `min_cycle_ns` is the longer of a non-load instruction
(`pc_to_imem_addr + insn_to_regs`) and a load (`pc_to_imem_addr + insn_to_dmem_addr + load_data_to_regs`), plus
the clock uncertainty. A real memory's access time adds to this twice.

## Status

Checked on 2026-11-17 with the testbench's stand-in core (`tb/selftest_core.v`, utilization 0.05 because the
design is tiny next to its 170 pins): synthesis, ICC2, post-layout simulation (pass), PrimeTime, PrimePower
(100% of the nets annotated from the SAIF), DRC clean and LVS pass. The real numbers come once `rv32i_core` passes
`make test`.

The CIC library is under NDA and is not included; the scripts expect it at
`/mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5` (override with `CBDK=...`).
