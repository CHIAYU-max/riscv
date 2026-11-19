#!/bin/bash
# Run the hls4ml projects from hls/gen_hls4ml.py with Vitis HLS on SOC: C simulation (checked against the
# expected output), C synthesis and, with VSYNTH=1, Vivado out-of-context synthesis for LUT / FF / DSP numbers.
#
# usage (on SOC, inside the copied build/hls4ml directory): bash run_soc.sh [project ...]
# Projects run in parallel; each writes <project>/run.log. Summary: hls_summary.txt
set -u
source /mnt/nfs/opt/Xilinx/Vitis_HLS/2020.2/settings64.sh >/dev/null 2>&1 || true
source /mnt/nfs/opt/Xilinx/Vivado/2020.2/settings64.sh >/dev/null 2>&1 || true
VSYNTH=${VSYNTH:-0}
cd "$(dirname "$0")"
projects=("$@")
[ ${#projects[@]} -eq 0 ] && projects=($(ls -d */ | tr -d /))

for p in "${projects[@]}"; do
    (cd "$p" && vitis_hls -f build_prj.tcl "reset=1 csim=1 synth=1 cosim=0 validation=0 export=0 vsynth=$VSYNTH" \
        > run.log 2>&1; echo "EXIT=$?" >> run.log) &
done
wait

{
for p in "${projects[@]}"; do
    echo "== $p"
    res=$(ls "$p"/tb_data/csim_results.log 2>/dev/null)
    if [ -n "$res" ]; then
        python3 - "$res" "$p/tb_data/tb_output_predictions.dat" <<'EOF'
import sys
got = [round(float(v)) for v in open(sys.argv[1]).read().split()]
exp = [round(float(v)) for v in open(sys.argv[2]).read().split()]
bad = sum(g != e for g, e in zip(got, exp))
print("csim: %s (%d / %d values differ)" % ("BIT-EXACT" if bad == 0 and len(got) == len(exp) else "MISMATCH", bad, len(exp)))
EOF
    else
        echo "csim: no results"
    fi
    rpt=$(ls "$p"/unet_block_prj/solution1/syn/report/unet_block_csynth.rpt 2>/dev/null)
    [ -n "$rpt" ] && sed -n '/Performance Estimates/,/Interface/p' "$rpt" | grep -E 'ns|cycles|Latency|^\s*\|' | head -12
    [ -n "$rpt" ] && sed -n '/Utilization Estimates/,/Detail/p' "$rpt" | grep -E 'Total|Available|Utilization' | head -4
    vs=$(ls "$p"/vivado_synth.rpt 2>/dev/null)
    [ -n "$vs" ] && grep -E 'CLB LUTs|Slice LUTs|Registers|DSPs|Block RAM' "$vs" | head -6
    tail -1 "$p/run.log"
done
} | tee hls_summary.txt
