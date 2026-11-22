# Spike cross-check of the golden model

`sw/iss.py` is the reference for every core test (`make trace`, `make random-test`). It was written
for this project, so a misreading of the ISA manual could sit in both the golden model and the core
and never show up as a mismatch. `make spike-check` compares `sw/iss.py` with Spike, the reference
RISC-V ISA simulator, on every retired instruction (pc, encoding, destination, value) and every store
(address, byte lanes, data).

```
make spike-check                  # rv32ui (39 tests), the C programs (sum fib sort muldiv putc), 50 random programs
make spike-check RAND_COUNT=200   # more random programs (RAND_SEED, RAND_LEN as for random-test)
sw/run_random.sh --spike --seed 7 --count 1   # one random program; traces in build/random/rand_7.*
```

Result on 2026-11-22: 44 / 44 fixed programs (30,374 instructions, 2,214 stores) and 200 / 200
random programs match. A one-bit change in one value of a Spike trace, a truncated trace and an empty
trace are all reported as DIFFER (checked by hand when the target was added).

## How it works

- `sw/spike_trace.py` runs the ELF on Spike with RAM at 0 (64 KiB, as in `tb_core.v`) and an I/O
  region at `0x8000_0000`, turns the commit log (`--log-commits`) into the `R` / `S` lines of
  `sw/iss.py --trace`, and stops at the store to TOHOST.
- `sw/spike_check.sh` runs both simulators on each program and compares them with `sw/trace_diff.py`
  (the report calls Spike "core", since the script was written for the core).
- `sw/run_random.sh --spike` does the same for the random programs of `sw/gen_random.py`.

## Limits

- Base RV32I only. Spike does not know `dot4`, `max4`, `requant`, `sdot4` / `sdot8`; programs that use
  them stop as ILLEGAL on Spike, and `--spike` refuses `--custom`. Covering them needs a Spike
  extension library (`--extlib`) with the same semantics as `sw/iss.py`; planned before the retire
  signature (5/8) or riscv-formal (5/22).
- Spike's boot ROM sets a0..a2 and t0 before jumping to 0. The rv32ui tests and the random programs
  clear every register first; crt0 does not read them.
- Spike has no timing: cycles still come from the RTL simulation and the board counters.
- The commit log does not record traps. A trap sends Spike to mtvec (0 after reset), so an
  instruction at pc 0 after the first one is reported as ILLEGAL.

## Installing Spike (WSL, no root)

Spike is built from source into `~/tools/spike` (commit `982f078e`, 2026-11-20, version 1.1.1-dev),
with one local change: the reset vector moved from `0x1000` to `0x2000_0000`, because the boot ROM
would otherwise overlap RAM at 0 (`devices at [0, 10000) and [1000, 2000) overlap`).

```
mkdir -p ~/tools/dl && cd ~/tools/dl
apt-get download device-tree-compiler libfdt1          # dtc, needed by Spike at run time
for f in *.deb; do dpkg -x "$f" ~/tools/dtc; done
cd ~/tools && git clone https://github.com/riscv-software-src/riscv-isa-sim.git
cd riscv-isa-sim && git checkout 982f078e && git submodule update --init --depth 1
sed -i 's/^#define DEFAULT_RSTVEC     0x00001000/#define DEFAULT_RSTVEC     0x20000000/' riscv/platform.h
mkdir build && cd build && ../configure --prefix=$HOME/tools/spike && make -j16 && make install
```

`sw/spike_trace.py` finds Spike and dtc there; set `SPIKE` (the spike binary) and `SPIKE_DTC` (the
directory holding dtc) to use other locations.
