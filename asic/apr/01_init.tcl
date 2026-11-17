# rv32i_core, adapted from the geofence ICC2 flow
# 01_init: design library, netlist, timing setup, floorplan, power plan
source common.tcl

file delete -force $DLIB
# local tf copy without the via*_fat contact codes: bar vias fail VIA5.W.1 (allowed only in seal rings)
create_lib $DLIB -technology tsmc13_CIC_nofat.tf -ref_libs [list $LIB/tsmc13gfsg.ndm $LIB/tsmc13gfsg_physical_only.ndm]
read_verilog $NETLIST -top rv32i_core
link_block

# tech file has no routing directions
foreach {l d} {METAL1 horizontal METAL2 vertical METAL3 horizontal METAL4 vertical
               METAL5 horizontal METAL6 vertical METAL7 horizontal METAL8 vertical} {
  set_attribute [get_layers $l] routing_direction $d
}
set_ignored_layers -max_routing_layer METAL6

read_parasitic_tech -tlup $LIB/tluplus/t013s8mg_fsg_typical.tluplus \
                    -layermap $LIB/tluplus/t013s8mg_fsg.map -name typical

remove_modes -all; remove_corners -all; remove_scenarios -all
create_mode func
create_corner slow
create_scenario -name func_slow -mode func -corner slow
set_parasitic_parameters -corners slow -early_spec typical -late_spec typical
current_scenario func_slow
source apr.sdc
set_scenario_status func_slow -setup true -hold true -leakage_power true -dynamic_power true
# fast corner (fast.lib: 1.32 V, -40 C) for hold only; the library ships one TLU+ file, used for both
create_corner fast
create_scenario -name func_fast -mode func -corner fast
set_parasitic_parameters -corners fast -early_spec typical -late_spec typical
set_scenario_status func_fast -setup false -hold true -leakage_power false -dynamic_power false
# clock uncertainty is per scenario: without this the fast corner is hold fixed with none
current_scenario func_fast
source apr.sdc
current_scenario func_slow

# floorplan: core utilization from common.tcl, 12 um ring channel
initialize_floorplan -core_utilization $UTIL -core_offset 12
place_pins -self

# power: global nets, core ring and mesh on METAL5/METAL6, M1 rails
connect_pg_net -automatic
connect_pg_net -net VDD [get_pins -hierarchical */VDD]
connect_pg_net -net VSS [get_pins -hierarchical */VSS]

# bind the corner to the slow library's PVT (slow.lib: process 1, 1.08 V, 125 C);
# without this ICC2 picks the 1.32 V fast library and reports optimistic timing
set_process_number 1 -corners slow
set_voltage 1.08 -corners slow -object_list [get_supply_nets VDD]
set_voltage 0.00 -corners slow -object_list [get_supply_nets VSS]
set_temperature 125 -corners slow
set_process_number 1 -corners fast
set_voltage 1.32 -corners fast -object_list [get_supply_nets VDD]
set_voltage 0.00 -corners fast -object_list [get_supply_nets VSS]
set_temperature -40 -corners fast

create_pg_ring_pattern ring -horizontal_layer METAL5 -vertical_layer METAL6 \
  -horizontal_width 2 -vertical_width 2 -horizontal_spacing 1 -vertical_spacing 1
set_pg_strategy ring_s -core -pattern {{name: ring} {nets: {VDD VSS}} {offset: {2 2}}}
compile_pg -strategies ring_s

# vertical stripes only: horizontal METAL5 stripes landed on VDD rails and blocked their via stacks
create_pg_mesh_pattern mesh -layers { {{vertical_layer: METAL6} {width: 1} {pitch: 30} {spacing: interleaving}} }
set_pg_strategy mesh_s -core -pattern {{name: mesh} {nets: {VDD VSS}}} -extension {{stop: outermost_ring}}
compile_pg -strategies mesh_s

create_pg_std_cell_conn_pattern rail -layers METAL1
# extend rails out to the ring so the top and bottom rails get vias too
set_pg_strategy rail_s -core -pattern {{name: rail} {nets: {VDD VSS}}} -extension {{stop: outermost_ring}}
compile_pg -strategies rail_s

check_pg_connectivity
check_pg_drc
save_block -as init
save_lib
puts "STAGE: init done"
