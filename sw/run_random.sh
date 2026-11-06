#!/bin/bash
# Random-program tests: generate programs with sw/gen_random.py, build them, and either run them on the
# golden model alone (checks the generator) or compare the core's trace with the golden model's.
#
# usage: sw/run_random.sh [--sim <vvp image>] [--custom] [--seed <first>] [--count <n>] [--length <n>]
#   without --sim   each program must PASS on sw/iss.py
#   with --sim      each program runs on the core and on sw/iss.py, and sw/trace_diff.py compares them
#                   (stores and the final register signature; also every retired instruction when the
#                   image was built with -DRETIRE_TRACE, i.e. build/sim_core_retire)
# Exits non-zero if any program fails; the failing seeds are listed, and build/random/rand_<seed>.*
# (assembly, dump, traces) are kept for debugging.
set -u
sim=""; custom=""; seed=1; count=20; length=300
while [ $# -gt 0 ]; do
    case $1 in
        --sim) sim=$2; shift 2 ;;
        --custom) custom=--custom; shift ;;
        --seed) seed=$2; shift 2 ;;
        --count) count=$2; shift 2 ;;
        --length) length=$2; shift 2 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done

prefix=${RISCV_PREFIX:-riscv64-unknown-elf-}
dir=build/random
mkdir -p $dir
iss_flags="--max-steps 100000 ${custom:+--dot4}"
pass=0; failed=()

for ((s = seed; s < seed + count; s++)); do
    name=rand_$s
    base=$dir/$name
    python3 sw/gen_random.py --seed $s --length $length $custom --out $base.S || { failed+=($s); continue; }
    if ! ${prefix}gcc -march=rv32i -mabi=ilp32 -static -nostdlib -nostartfiles -T sw/env/link.ld -Wl,--no-warn-rwx-segments -Isw/env \
            $base.S -o $base.elf; then
        echo "BUILD   $name"; failed+=($s); continue
    fi
    ${prefix}objcopy -O binary $base.elf $base.bin
    python3 sw/bin2hex.py $base.bin $base.hex
    ${prefix}objdump -d $base.elf > $base.dump

    if [ -z "$sim" ]; then
        if line=$(python3 sw/iss.py $iss_flags $base.hex); then pass=$((pass + 1)); else echo "$line"; failed+=($s); fi
        continue
    fi
    vvp -n $sim +HEX=$base.hex +NAME=$name +TRACE=$base.core > $base.sim.log
    python3 sw/iss.py $iss_flags $base.hex --trace $base.ref > /dev/null
    if python3 sw/trace_diff.py $base.ref $base.core --dump $base.dump > $base.diff; then
        pass=$((pass + 1))
    else
        echo "DIFFER  $name (seed $s): $(grep -m1 MISMATCH $base.diff)"
        failed+=($s)
    fi
done

echo "----"
echo "$pass / $count random programs passed${sim:+ (core vs golden model)}"
if [ ${#failed[@]} -gt 0 ]; then
    echo "failed seeds: ${failed[*]}  (details: $dir/rand_<seed>.diff, rerun one with --seed <s> --count 1)"
    exit 1
fi
