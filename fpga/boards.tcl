# Board table for build.tcl and fmax.tcl: part, top level and pin file per board.
# Add a board here, with its top level in fpga/rtl/<board>_top.v and its pins in fpga/<board>.xdc.
#   basys3    Digilent Basys3        XC7A35T-1CPG236C
#   nexys_a7  Digilent Nexys A7-100T XC7A100T-1CSG324C (docs/nexys-a7.md)
set boards {
    basys3   {part xc7a35tcpg236-1  top basys3_top   xdc fpga/basys3.xdc}
    nexys_a7 {part xc7a100tcsg324-1 top nexys_a7_top xdc fpga/nexys_a7.xdc}
}

proc board_get {board key} {
    global boards
    if {![dict exists $boards $board]} {
        error "unknown board '$board' (known: [dict keys $boards])"
    }
    return [dict get $boards $board $key]
}

# Reads the board-independent RTL, the board's own top level and the core sources.
proc read_board_sources {board core_rtl} {
    set top [board_get $board top]
    foreach f [glob fpga/rtl/*.v] {
        set name [file rootname [file tail $f]]
        # other boards' top levels are left out
        if {[string match *_top $name] && $name ne $top} { continue }
        read_verilog $f
    }
    foreach f $core_rtl {
        if {[file extension $f] eq ".sv"} { read_verilog -sv $f } else { read_verilog $f }
    }
    read_xdc [board_get $board xdc]
}
