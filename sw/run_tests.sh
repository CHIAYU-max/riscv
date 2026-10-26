#!/bin/bash
# Run each hex file on the compiled testbench and print a summary.
# usage: sw/run_tests.sh <vvp image> <hex>...
# Exits non-zero if any test does not pass.
sim=$1
shift
pass=0
failed=()
for hex in "$@"; do
    name=$(basename "$hex" .hex)
    line=$(vvp -n "$sim" +HEX="$hex" +NAME="$name" | grep -E '^(PASS|FAIL|TIMEOUT|BADADDR|ERROR)' | tail -1)
    echo "${line:-ERROR   $name: no result}"
    if [[ $line == PASS* ]]; then pass=$((pass + 1)); else failed+=("$name"); fi
done
echo "----"
echo "$pass / $# passed"
if [ ${#failed[@]} -gt 0 ]; then
    echo "failed: ${failed[*]}"
    exit 1
fi
