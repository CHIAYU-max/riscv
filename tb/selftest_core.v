`timescale 1ns / 1ps
// Stand-in for rv32i_core used by `make selftest` to check tb_core.v itself
// (program loading, store byte lanes, TOHOST detection) before the real core exists.
// It is not a processor: it writes a test pattern to RAM, reads it back,
// and reports pass to TOHOST if the program word at address 0 and the readback match.
module rv32i_core (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output reg  [31:0] dmem_addr,
    output reg  [31:0] dmem_wdata,
    output reg  [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata
);

    localparam TOHOST = 32'h8000_0000;

    reg [2:0] step;
    assign imem_addr = 32'h0000_0000;

    always @(posedge clk) begin
        if (rst) begin
            step       <= 3'd0;
            dmem_addr  <= 32'h0000_0100;
            dmem_wdata <= 32'h0000_0000;
            dmem_wstrb <= 4'b0000;
        end else begin
            step <= step + 3'd1;
            case (step)
                // two byte stores into the same word: 0x0000_aa00 then 0xbb00_aa00
                3'd0: begin dmem_addr <= 32'h0000_0100; dmem_wdata <= 32'h0000_aa00; dmem_wstrb <= 4'b0010; end
                3'd1: begin dmem_addr <= 32'h0000_0103; dmem_wdata <= 32'hbb00_0000; dmem_wstrb <= 4'b1000; end
                3'd2: begin dmem_addr <= 32'h0000_0100; dmem_wstrb <= 4'b0000; end
                3'd3: begin
                    dmem_addr  <= TOHOST;
                    dmem_wstrb <= 4'b1111;
                    // fail codes: test 1 = program not loaded, test 2 = byte lanes wrong
                    dmem_wdata <= (imem_rdata != 32'h0000_0013) ? 32'd3 :
                                  (dmem_rdata != 32'hbb00_aa00) ? 32'd5 : 32'd1;
                end
                default: dmem_wstrb <= 4'b0000;
            endcase
        end
    end

endmodule
