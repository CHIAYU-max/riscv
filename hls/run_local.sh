#!/bin/bash
# Run hls4ml projects with the local Vitis 2025.2.1 (WSL): csim + csynth + cosim, then Vivado out-of-context
# synthesis (vsynth_ooc.tcl). hls4ml's build_prj.tcl ignores command-line options and reads build_opt.tcl, so
# that file is rewritten here.
# usage: hls/run_local.sh <dir with projects> [project ...]
set -u
source /Xilinx/2025.2.1/Vitis/settings64.sh >/dev/null 2>&1
source /Xilinx/2025.2.1/Vivado/settings64.sh >/dev/null 2>&1
root=$(cd "$1" && pwd); shift
here=$(cd "$(dirname "$0")" && pwd)
projects=("$@")
[ ${#projects[@]} -eq 0 ] && projects=($(cd "$root" && ls -d */ | tr -d /))
for p in "${projects[@]}"; do
    (
        cd "$root/$p" || exit
        cat > build_opt.tcl <<'EOF'
array set opt {
    reset      1
    csim       1
    synth      1
    cosim      1
    validation 0
    export     0
    vsynth     0
    fifo_opt   0
}
EOF
        vitis-run --mode hls --tcl build_prj.tcl > run.log 2>&1; echo "EXIT=$?" >> run.log
        vivado -mode batch -nojournal -source "$here/vsynth_ooc.tcl" > vsynth.log 2>&1; echo "VEXIT=$?" >> vsynth.log
    ) &
done
wait
echo ALL_DONE
