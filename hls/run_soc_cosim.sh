#!/bin/bash
# usage (on SOC): copy the generated projects and hls/vsynth_ooc.tcl into one directory, put this script next to
# them, then  nohup bash run_soc_cosim.sh > soc_full.log 2>&1 &  (2026-11-21 whole-layer run, docs/hls4ml-baseline.md)
# SOC, Vitis HLS / Vivado 2020.2: csim + csynth + cosim + validation (csim vs RTL cosim), then Vivado OOC synthesis,
# for every project in this directory, all in parallel. Summary at the end.
set -u
source /mnt/nfs/opt/Xilinx/Vitis_HLS/2020.2/settings64.sh >/dev/null 2>&1 || true
source /mnt/nfs/opt/Xilinx/Vivado/2020.2/settings64.sh >/dev/null 2>&1 || true
cd "$(dirname "$0")"
for p in $(ls -d */ | tr -d /); do
    (
        cd "$p" || exit
        cat > build_opt.tcl <<'EOF'
array set opt {
    reset      1
    csim       1
    synth      1
    cosim      1
    validation 1
    export     0
    vsynth     0
    fifo_opt   0
}
EOF
        vitis_hls -f build_prj.tcl > run.log 2>&1; echo "EXIT=$?" >> run.log
        vivado -mode batch -nojournal -source ../vsynth_ooc.tcl > vsynth.log 2>&1; echo "VEXIT=$?" >> vsynth.log
    ) &
done
wait
echo SOC_FULL_DONE
