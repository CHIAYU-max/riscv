#!/bin/bash
# Compare the golden model (sw/iss.py) with Spike, instruction by instruction, on built programs.
# Each <elf> needs its .hex and .dump next to it (the build rules in the Makefile make all three).
#
# usage: sw/spike_check.sh build/tests/add.elf build/c/fib.elf ...
# Exits non-zero if any program differs; the traces stay in build/spike/<name>.{ref,spike,diff}.
set -u
dir=build/spike
mkdir -p $dir
pass=0; failed=()
for elf in "$@"; do
    name=$(basename "$elf" .elf)
    base=${elf%.elf}
    python3 sw/iss.py $base.hex --trace $dir/$name.ref > $dir/$name.iss.log
    steps=$(grep -c '^R' $dir/$name.ref)
    python3 sw/spike_trace.py $elf --trace $dir/$name.spike --max-steps $steps > $dir/$name.spike.log
    if python3 sw/trace_diff.py $dir/$name.ref $dir/$name.spike --dump $base.dump > $dir/$name.diff; then
        pass=$((pass + 1))
    else
        echo "DIFFER  $name: $(cat $dir/$name.iss.log) / $(cat $dir/$name.spike.log)"
        grep -m1 -A8 MISMATCH $dir/$name.diff | sed 's/^/        /'
        failed+=($name)
    fi
done
echo "----"
echo "$pass / $# programs: golden model and Spike retire the same instructions and stores"
if [ ${#failed[@]} -gt 0 ]; then
    echo "differ: ${failed[*]}  (details: $dir/<name>.diff)"
    exit 1
fi
