// Basys3 top level: rv32i_core + 8 KiB memory + memory-mapped I/O.
//
// Clock: the 100 MHz board clock goes through an MMCM to CORE_MHZ (default 25 MHz).
// Raise CORE_MHZ once the core meets timing (check the Vivado timing report).
// Reset: BTNC, synchronized to the core clock and held until the MMCM locks.
//
// Memory map (README "Memory map"):
//   0x0000_0000  RAM, 8 KiB, loaded from INIT_FILE at configuration
//   0x8000_0000  TOHOST  write: result latch, shown on the display, LED15 = done
//   0x8000_0004  LED     write: LED[15:0] (LED15 is replaced by "done" after a TOHOST write)
//   0x8000_0008  SEG     write: 16-bit value shown as 4 hex digits
//   0x8000_000C  SW      read : SW[15:0], two-flop synchronized
module basys3_top #(
    parameter INIT_FILE = "",
    parameter CORE_MHZ  = 25            // 100 * 10 / CLKOUT0_DIVIDE; 25 or 50
) (
    input  wire        clk,             // 100 MHz
    input  wire        btnC,            // reset
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an
);

    // ------------------------------------------------------------------
    // Clock and reset
    wire clk_fb, clk_core_unbuf, clk_core, locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .CLKFBOUT_MULT_F  (10.0),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F (1000.0 / CORE_MHZ)
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_core_unbuf),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3  (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .CLKFBOUTB()
    );

    BUFG u_bufg (.I(clk_core_unbuf), .O(clk_core));

    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk_core or negedge locked) begin
        if (!locked) rst_sync <= 2'b11;
        else rst_sync <= {rst_sync[0], btnC};
    end
    wire rst = rst_sync[1];

    // ------------------------------------------------------------------
    // Core
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;

    rv32i_core u_core (
        .clk        (clk_core),
        .rst        (rst),
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

    fpga_mem #(.INIT_FILE(INIT_FILE)) u_mem (
        .clk    (clk_core),
        .iaddr  (imem_addr),
        .irdata (imem_rdata),
        .daddr  (dmem_addr),
        .dwdata (dmem_wdata),
        .dwstrb (is_io ? 4'b0000 : dmem_wstrb),
        .drdata (ram_rdata)
    );

    reg  [15:0] sw_meta, sw_sync;
    reg  [15:0] led_q;
    reg  [15:0] seg_q;
    reg         done_q;

    always @(posedge clk_core) begin
        sw_meta <= sw;
        sw_sync <= sw_meta;
    end

    always @(posedge clk_core) begin
        if (rst) begin
            led_q  <= 16'h0000;
            seg_q  <= 16'h0000;
            done_q <= 1'b0;
        end else if (is_io && (|dmem_wstrb)) begin
            case (dmem_addr[3:2])
                2'd0: begin seg_q <= dmem_wdata[15:0]; done_q <= 1'b1; end   // TOHOST
                2'd1: led_q <= dmem_wdata[15:0];
                2'd2: seg_q <= dmem_wdata[15:0];
                default: ;
            endcase
        end
    end

    assign dmem_rdata = !is_io ? ram_rdata :
                        (dmem_addr[3:2] == 2'd3) ? {16'h0000, sw_sync} : 32'h0000_0000;

    // ------------------------------------------------------------------
    // Outputs
    assign led = {done_q | led_q[15], led_q[14:0]};
    assign dp  = 1'b1;

    seg7_hex u_seg (
        .clk   (clk_core),
        .rst   (rst),
        .value (seg_q),
        .seg   (seg),
        .an    (an)
    );

endmodule
