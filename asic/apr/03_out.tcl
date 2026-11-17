# rv32i_core, adapted from the geofence ICC2 flow
# 03_out: write netlists, SDF, SPEF, DEF and GDS from the final block
source common.tcl
open_lib $DLIB
open_block final
link_block

# DC can leave nets such as N157 and n157 in one module; ICV LVS is case-insensitive and merges them
define_name_rules lvs_nocase -case_insensitive
change_names -rules lvs_nocase -hierarchy

# an unused output (e.g. QN) can sit on a net with no other pin: it exists in the netlist but has
# no wire in the layout, so black-box LVS reports a port mismatch; disconnect such dangling nets
set dangling 0
foreach_in_collection n [get_nets -hierarchical -filter "net_type==signal"] {
  if {[sizeof_collection [get_pins -quiet -of_objects $n]] + [sizeof_collection [get_ports -quiet -of_objects $n]] == 1} {
    disconnect_net -net $n -all
    incr dangling
  }
}
puts "STAGE: disconnected $dangling dangling nets"

file mkdir out
write_verilog -exclude {pg_objects leaf_module_declarations end_cap_cells well_tap_cells filler_cells physical_only_cells} out/core_apr.v
# netlist with VDD/VSS pins and fillers for ICV LVS (fillers are black boxes in the GDS too)
write_verilog -exclude {leaf_module_declarations} out/core_apr_pg.v
write_sdf -significant_digits 4 out/core_apr.sdf
write_parasitics -format spef -output out/core_apr
write_def -include_tech_via_definitions out/core_apr.def
# port labels for LVS: METALn text goes on TEXTn (GDS 131-138)
foreach_in_collection t [get_terminals -of_objects [get_ports *]] {
  set n [string index [get_attribute $t layer.name] end]
  set bb [get_attribute $t bbox]
  set x [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}]
  set y [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]
  create_shape -shape_type text -layer TEXT$n -origin [list $x $y] -height 0.5 -text [get_attribute [get_ports -of_objects $t] name]
}
# VDD/VSS have no terminals: label their METAL6 ring segments
foreach net {VDD VSS} {
  set r [index_collection [get_shapes -of_objects [get_nets $net] -filter "shape_use==ring && layer_name==METAL6"] 0]
  set bb [get_attribute $r bbox]
  create_shape -shape_type text -layer TEXT6 -height 0.5 -text $net \
    -origin [list [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}] [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]]
}
write_gds -design final -long_names -layer_map $LIB/stout.map -keep_data_type \
  -merge_files /mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5/Phantom/tsmc13gfsg_fram.gds out/core.gds
puts "STAGE: out done"
