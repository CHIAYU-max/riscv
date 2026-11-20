// Nexys A7-100T top level: clock, reset and display around soc.v (core + memory + memory-mapped I/O).
// Main board. Same memory map as the Basys3 build (docs/nexys-a7.md), 32 KiB RAM; the differences are here:
//
// Clock: the 100 MHz board clock (E3) goes through an MMCM to CORE_MHZ (default 25 MHz).
// Reset: CPU_RESETN (the red button, active low), synchronized and held until the MMCM locks.
// Display: all 32 bits of SEG / TOHOST as 8 hex digits. LED15 lights after a TOHOST store.
module nexys_a7_top #(
    parameter INIT_FILE = "",
    parameter CORE_MHZ  = 25,
    parameter MEM_KIB   = 32            // matches sw/c/link.ld; 8 = the Basys3 size
) (
    input  wire        clk,             // 100 MHz
    input  wire        cpu_resetn,      // reset, active low
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [7:0]  an
);

    // ------------------------------------------------------------------
    // Clock and reset
    wire clk_core, locked;

    board_clk #(.CORE_MHZ(CORE_MHZ)) u_clk (
        .clk_100m_i (clk),
        .clk_core_o (clk_core),
        .locked_o   (locked)
    );

    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk_core or negedge locked) begin
        if (!locked) rst_sync <= 2'b11;
        else rst_sync <= {rst_sync[0], ~cpu_resetn};
    end
    wire rst = rst_sync[1];

    // ------------------------------------------------------------------
    // Core, memory and I/O
    wire [15:0] led_value;
    wire [31:0] seg_value;
    wire        done;

    soc #(.INIT_FILE(INIT_FILE), .MEM_KIB(MEM_KIB)) u_soc (
        .clk_i       (clk_core),
        .rst_i       (rst),
        .sw_i        (sw),
        .led_o       (led_value),
        .seg_value_o (seg_value),
        .done_o      (done)
    );

    // ------------------------------------------------------------------
    // Outputs
    assign led = {done | led_value[15], led_value[14:0]};
    assign dp  = 1'b1;

    seg7_hex #(.DIGITS(8)) u_seg (
        .clk   (clk_core),
        .rst   (rst),
        .value (seg_value),
        .seg   (seg),
        .an    (an)
    );

endmodule
