#!/bin/bash
# ASIC flow for rv32i_core in TSMC 0.13 um (CIC tsmc13 library), adapted from the geofence flow
# (github.com/CHIAYU-max/geofence-rtl-to-gdsii): Design Compiler -> IC Compiler II -> post-layout simulation
# of real programs with the ICC2 SDF -> PrimeTime STA and PrimePower with the ICC2 SPEF -> ICV DRC and LVS.
#
# usage (on the server, from the repository root):
#   asic/run_asic.sh <tag> <cycle_ns> "<core sources>" <program.hex>...
#   e.g. asic/run_asic.sh base 10 "rtl/rv_pkg.sv rtl/alu.sv ... rtl/rv32i_core.sv" build/c/block_ref.hex
# environment: DEFINES="USE_DOT4 ..." (Verilog defines for the core), UTIL (core utilization, default 0.6),
#              SKIP_SIGNOFF=1 skips DRC / LVS, MAX_CYCLES (per program, default 20000000)
# output: asic/runs/<tag>/ (reports in rpt/) and one line per program in asic/runs/summary.csv
#
# The core's memories are outside the core (README "Core interface"), so the synthesized design is the core
# alone: register file, decoder, ALU and any custom units. The ports are constrained with zero I/O delay and
# the report splits the cycle into the segments around the two memory reads (asic/README.md).
set -e
[ $# -ge 4 ] || { sed -n 2,14p "$0"; exit 1; }
TAG=$1 CYCLE=$2 CORE=$3; shift 3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASIC=$ROOT/asic
LIB=${CBDK:-/mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5}
UTIL=${UTIL:-0.6}
MAX_CYCLES=${MAX_CYCLES:-20000000}
export VERDI_HOME=${VERDI_HOME:-/mnt/nfs/opt/EDA/synopsys/verdi/cur}
D=$ASIC/runs/$TAG
SUMMARY=$ASIC/runs/summary.csv
HALF=$(awk -v c=$CYCLE 'BEGIN{printf "%g", c/2}')

SRC=""; for f in $CORE; do SRC="$SRC $ROOT/$f"; done
HEXES=""; for h in "$@"; do HEXES="$HEXES $ROOT/$h"; done
rm -rf $D && mkdir -p $D/rpt $D/out && cd $D
echo "$(date '+%F %T') $TAG start (cycle $CYCLE ns, util $UTIL)"

# ---- synthesis ----
sed "s#/cad/CBDK/CBDK_IC_Contest_v2.1#$LIB#" $ASIC/synopsys_dc.setup > .synopsys_dc.setup
sed "s/^set cycle .*/set cycle $CYCLE/" $ASIC/core.sdc > core.sdc
cp $ASIC/pt_io.sdc .
cat > syn.tcl <<EOF
set_svf core.svf
analyze -format sverilog -define {$DEFINES} {$SRC}
elaborate rv32i_core
current_design rv32i_core
link
source -echo -verbose core.sdc
check_design > rpt/check_design.rpt
set high_fanout_net_threshold 0
uniquify
set_fix_multiple_port_nets -all -buffer_constants [get_designs *]
compile_ultra -no_autoungroup
change_names -rules verilog -hierarchy
write -format ddc -hierarchy -output core_syn.ddc
write -format verilog -hierarchy -output core_syn.v
report_area > rpt/syn_area.rpt
report_area -hierarchy -nosplit > rpt/syn_area_hier.rpt
report_timing -max_paths 5 > rpt/syn_timing.rpt
report_qor > rpt/syn_qor.rpt
exit
EOF
dc_shell -f syn.tcl < /dev/null > dc.log 2>&1 || true
[ -s core_syn.v ] || { echo "FAIL synthesis (see $D/dc.log)"; grep -E "^Error" dc.log | head; exit 1; }
grep -E "^(Warning|Error).*(Latch|latch|LINT)" dc.log | head -5 || true

# ---- place and route (ICC2) ----
[ -f $ASIC/apr/tsmc13_CIC_nofat.tf ] || awk '/ContactCode.*_fat/{f=1} f&&/^}/{f=0;next} !f' $LIB/ICC2/tsmc13_CIC.tf > $ASIC/apr/tsmc13_CIC_nofat.tf
ln -sf $ASIC/apr/tsmc13_CIC_nofat.tf .
cp $ASIC/apr/01_init.tcl $ASIC/apr/02_pnr.tcl $ASIC/apr/03_out.tcl .
cat > common.tcl <<EOF
set LIB     $LIB/ICC2
set NETLIST core_syn.v
set DLIB    core.dlib
set UTIL    $UTIL
set_host_options -max_cores 4
EOF
sed "s/^set cycle .*/set cycle $CYCLE/" $ASIC/apr/apr.sdc > apr.sdc
for s in 01_init 02_pnr 03_out; do
    timeout 7200 icc2_shell -f $s.tcl -output_log_file $s.log < /dev/null > /dev/null 2>&1 || true
    grep -q "STAGE: ${s#*_} done" $s.log || { echo "FAIL $s (see $D/$s.log)"; grep "^Error" $s.log | head; exit 1; }
done

# ---- STA (PrimeTime): setup at the slow corner, hold at slow and fast, cycle split into segments ----
SPEF=$(ls out/*_125.spef | head -1)
SPEF_FAST=$(ls out/*_-40.spef | head -1)
pt_common() {  # $1 = library db, $2 = SPEF, $3 = "power" to enable PrimePower (must come before link)
[ "$3" = power ] && printf 'set power_enable_analysis true\nset power_analysis_mode averaged\n'
cat <<EOF
set search_path ". $LIB/SynopsysDC/db"
set link_library "* $1"
read_verilog out/core_apr.v
current_design rv32i_core
link
set cycle $CYCLE
create_clock -name clk -period \$cycle [get_ports clk]
set_clock_uncertainty 0.1 [all_clocks]
set_propagated_clock [all_clocks]
source pt_io.sdc
read_parasitics -format spef $2
EOF
}
{ pt_common fast.db $SPEF_FAST
  echo "report_timing -delay_type min -max_paths 3 -slack_lesser_than 1000 > rpt/pt_fast_timing_min.rpt"; echo exit; } > pt_fast.tcl
timeout 1800 pt_shell -f pt_fast.tcl < /dev/null > pt_fast.log 2>&1 || true
{ pt_common slow.db $SPEF
  cat <<'EOF'
report_annotated_parasitics > rpt/pt_annotated.rpt
report_timing -delay_type max -max_paths 3 -slack_lesser_than 1000 > rpt/pt_timing_max.rpt
report_timing -delay_type min -max_paths 3 -slack_lesser_than 1000 > rpt/pt_timing_min.rpt
# Delay of the four segments of a single-cycle instruction around the external memories (pt_io.sdc):
# arrival minus the input delay at the start, plus the flip-flop setup time at a register endpoint.
set seg [open rpt/pt_segments.txt w]
foreach {name from to din} [list \
    pc_to_imem_addr     [all_registers -clock_pins] [get_ports imem_addr*]     0 \
    insn_to_dmem_addr   [get_ports imem_rdata*]     [get_ports dmem_addr*]     $t_insn \
    insn_to_regs        [get_ports imem_rdata*]     [all_registers -data_pins] $t_insn \
    load_data_to_regs   [get_ports dmem_rdata*]     [all_registers -data_pins] $t_load] {
    set p [get_timing_paths -delay_type max -from $from -to $to]
    if {[sizeof_collection $p] == 0} { puts $seg "$name n/a"; continue }
    set d [expr {[get_attribute $p arrival] - $din}]
    set su [get_attribute -quiet $p endpoint_setup_time_value]
    if {$su ne ""} { set d [expr {$d + $su}] }
    puts $seg "$name [format %.3f $d]"
}
close $seg
EOF
  echo exit; } > pt.tcl
timeout 1800 pt_shell -f pt.tcl < /dev/null > pt.log 2>&1 || true
SETUP=$(awk '/slack \(/{print $NF; exit}' rpt/pt_timing_max.rpt)
HOLD=$(awk '/slack \(/{print $NF; exit}' rpt/pt_timing_min.rpt)
HOLD_FAST=$(awk '/slack \(/{print $NF; exit}' rpt/pt_fast_timing_min.rpt)
seg() { awk -v n=$1 '$1==n{print $2}' rpt/pt_segments.txt; }
# shortest cycle with zero-delay memories: the longer of a non-load and a load instruction, plus the uncertainty
MIN_CYCLE=$(awk '{v[$1]=$2} END{a=v["pc_to_imem_addr"]; if (a=="n/a" || a=="") {print ""; exit}
    m=a+v["insn_to_regs"]; l=a+v["insn_to_dmem_addr"]+v["load_data_to_regs"]; if (l>m) m=l; printf "%.2f", m+0.1}' rpt/pt_segments.txt)

CELLS=$(awk '/Leaf Cell Count/{print $NF; exit}' rpt/final_qor.rpt)
AREA=$(awk '/Cell Area \(netlist\):/{print $NF; exit}' rpt/final_qor.rpt)
CORE_AREA=$(awk '/^Total Area:/{print $NF; exit}' rpt/utilization.rpt)
UTIL_REAL=$(awk '/Utilization Ratio/{print $NF; exit}' rpt/utilization.rpt)

# ---- DRC and black-box LVS (ICV) ----
DRC=skipped LVS=skipped
if [ -z "$SKIP_SIGNOFF" ]; then
    mkdir -p drc lvs
    cp $LIB/icv/drc/ICV13S_8M.drc.rs drc/
    cp $LIB/icv/lvs/* lvs/
    grep -q remove_schematic_ports lvs/lvs_black_box.rs || sed -i "s/^lvs_black_box_options(/lvs_black_box_options(\nremove_schematic_ports = {\"Q\", \"QN\"},/" lvs/lvs_black_box.rs
    (cd drc && icv -i ../out/core.gds -c rv32i_core -host_init 4 ICV13S_8M.drc.rs > icv_drc.out 2>&1) || true
    (cd lvs && icv_nettran -outType SPICE -verilog ../out/core_apr_pg.v -outName verilog2spice.sp > nettran.out 2>&1 &&
        icv -vue -i ../out/core.gds -c rv32i_core -s verilog2spice.sp -stc rv32i_core -sf SPICE -host_init 4 ICV_LVS.rs > icv_lvs.out 2>&1) || true
    DRC=$(grep -oE "RESULTS: [A-Z ]+" drc/rv32i_core.RESULTS 2>/dev/null | head -1 | awk '{print $2$3}')
    LVS=$(grep -oE "LVS Compare Results: [A-Z]+" lvs/rv32i_core.RESULTS 2>/dev/null | awk '{print $NF}')
fi

# ---- per program: post-layout simulation with SDF, switching activity (SAIF), PrimePower ----
[ -f $SUMMARY ] || echo "tag,program,defines,cycle_ns,cells,cell_area_um2,core_area_um2,util,setup_slack_ns,hold_slow_ns,hold_fast_ns,pc_to_imem_addr_ns,insn_to_dmem_addr_ns,insn_to_regs_ns,load_data_to_regs_ns,min_cycle_ns,post_sim,cycles,power_mW,energy_nJ,drc,lvs" > $SUMMARY
mkdir -p sim && cd sim
vcs -full64 -sverilog +define+TB_HALF_PERIOD=$HALF +maxdelays +neg_tchk -debug_access+all \
    -sdf max:tb_core.dut:../out/core_apr.sdf $ROOT/tb/tb_core.v ../out/core_apr.v -v $LIB/Verilog/tsmc13_neg.v \
    -l vcs_compile.log > /dev/null 2>&1 || { echo "FAIL post-layout simulation build (see $D/sim/vcs_compile.log)"; exit 1; }
cd ..
for hex in $HEXES; do
    P=$(basename $hex .hex)
    # the testbench ends with \$finish; endofsim noexit keeps UCLI alive to write the SAIF afterwards
    cat > sim/$P.ucli <<EOF
config endofsim noexit
power -gate_level on
power tb_core.dut
power -enable
run
power -disable
power -report $P.saif 1e-09 tb_core.dut
quit
EOF
    (cd sim && timeout 14400 ./simv +HEX=$hex +NAME=$P +MAX_CYCLES=$MAX_CYCLES -ucli -ucli2Proc -do $P.ucli -l $P.log \
        < /dev/null > /dev/null 2>&1) || true
    RES=$(grep -oE "^(PASS|FAIL|TIMEOUT|BADADDR|ERROR)" sim/$P.log | tail -1)
    CYC=$(grep -oE "\(([0-9]+) cycles\)" sim/$P.log | tail -1 | grep -oE "[0-9]+")
    P_MW="" E_NJ=""
    if [ "$RES" = PASS ] && [ -s sim/$P.saif ]; then
        { pt_common slow.db $SPEF power
          echo "read_saif -strip_path tb_core/dut sim/$P.saif"
          echo "update_power"
          echo "report_switching_activity > rpt/pwr_${P}_activity.rpt"
          echo "report_power > rpt/pwr_${P}.rpt"
          echo "report_power -hierarchy > rpt/pwr_${P}_hier.rpt"
          echo exit; } > pwr_$P.tcl
        timeout 3600 pt_shell -f pwr_$P.tcl < /dev/null > pwr_$P.log 2>&1 || true
        read PW UNIT < <(awk '/^ *Total Power *=/{print $4, $5; exit}' rpt/pwr_${P}.rpt)
        P_MW=$(awk -v p=$PW -v u=$UNIT 'BEGIN{m=(u=="W")?1000:(u=="mW")?1:(u=="uW")?0.001:1000; printf "%.4f", p*m}')
        E_NJ=$(awk -v p=$P_MW -v c=$CYC -v t=$CYCLE 'BEGIN{printf "%.2f", p*1e-3*c*t*1e-9*1e9}')
    fi
    echo "$TAG,$P,\"$DEFINES\",$CYCLE,$CELLS,$AREA,$CORE_AREA,$UTIL_REAL,$SETUP,$HOLD,$HOLD_FAST,$(seg pc_to_imem_addr),$(seg insn_to_dmem_addr),$(seg insn_to_regs),$(seg load_data_to_regs),$MIN_CYCLE,${RES:-ERROR},$CYC,$P_MW,$E_NJ,$DRC,$LVS" >> $SUMMARY
    echo "  $P: ${RES:-ERROR} ${CYC:-?} cycles, ${P_MW:-?} mW, ${E_NJ:-?} nJ"
done
rm -rf sim/simv.daidir sim/csrc sim/ucli.key core.dlib
echo "$(date '+%F %T') $TAG done: area $AREA um2, setup slack $SETUP ns, hold $HOLD / $HOLD_FAST ns, min cycle ${MIN_CYCLE:-n/a} ns, DRC $DRC, LVS $LVS"
