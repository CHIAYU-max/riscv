`default_nettype none
module pc_reg(
    input   logic       clk, rst,
    input   logic[31:0] next_pc,
    output  logic[31:0] pc
);

    always_ff@(posedge clk) begin
        if(rst) begin
            pc <= 32'd0;
        end else begin
            pc <= next_pc;
        end
    end

endmodule
`default_nettype wire
