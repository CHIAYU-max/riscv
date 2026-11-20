// Board-independent part of the FPGA design: rv32i_core + RAM + memory-mapped I/O.
// The board top levels (basys3_top.v, nexys_a7_top.v) add the clock, the reset synchronizer and the
// display driver, and map the outputs to the board's pins (docs/nexys-a7.md, "Structure").
//
// Memory map (README "Memory map"):
//   0x0000_0000  RAM, MEM_KIB KiB, loaded from INIT_FILE at configuration
//   0x8000_0000  TOHOST  write: result latch (also shown on the display), done_o = 1
//   0x8000_0004  LED     write: led_o[15:0]
//   0x8000_0008  SEG     write: seg_value_o[31:0] (a 4-digit display shows bits [15:0])
//   0x8000_000C  SW      read : sw_i[15:0] (synchronized here, two flops)
module soc #(
    parameter INIT_FILE = "",
    parameter MEM_KIB   = 32            // 32 (Nexys A7) or 8 (Basys3); must be a power of two
) (
    input  wire        clk_i,
    input  wire        rst_i,           // synchronous, active high, already synchronized to clk_i
    input  wire [15:0] sw_i,
    output wire [15:0] led_o,
    output wire [31:0] seg_value_o,
    output wire        done_o           // a TOHOST store has happened
);

    localparam WORDS = MEM_KIB * 256;
    localparam AW    = $clog2(WORDS);

    // ------------------------------------------------------------------
    // Core
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;

    rv32i_core u_core (
        .clk        (clk_i),
        .rst        (rst_i),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_rdata (dmem_rdata)
    );

    // ------------------------------------------------------------------
    // Memory and I/O decode
    wire        is_io = dmem_addr[31];
    wire [31:0] ram_rdata;

    fpga_mem #(.WORDS(WORDS), .AW(AW), .INIT_FILE(INIT_FILE)) u_mem (
        .clk    (clk_i),
        .iaddr  (imem_addr),
        .irdata (imem_rdata),
        .daddr  (dmem_addr),
        .dwdata (dmem_wdata),
        .dwstrb (is_io ? 4'b0000 : dmem_wstrb),
        .drdata (ram_rdata)
    );

    reg  [15:0] sw_meta_q, sw_sync_q;
    reg  [15:0] led_q;
    reg  [31:0] seg_q;
    reg         done_q;

    always @(posedge clk_i) begin
        sw_meta_q <= sw_i;
        sw_sync_q <= sw_meta_q;
    end

    always @(posedge clk_i) begin
        if (rst_i) begin
            led_q  <= 16'h0000;
            seg_q  <= 32'h0000_0000;
            done_q <= 1'b0;
        end else if (is_io && (|dmem_wstrb)) begin
            case (dmem_addr[3:2])
                2'd0: begin seg_q <= dmem_wdata; done_q <= 1'b1; end   // TOHOST
                2'd1: led_q <= dmem_wdata[15:0];
                2'd2: seg_q <= dmem_wdata;
                default: ;
            endcase
        end
    end

    assign dmem_rdata = !is_io ? ram_rdata :
                        (dmem_addr[3:2] == 2'd3) ? {16'h0000, sw_sync_q} : 32'h0000_0000;

    assign led_o       = led_q;
    assign seg_value_o = seg_q;
    assign done_o      = done_q;

endmodule
