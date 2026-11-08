`default_nettype none
module regfile_32x32_2r (
    input  logic        Clock,
    input  logic        Write_Enable,

    // 5bit address
    input  logic [4:0]  Write_Addr,
    input  logic [4:0]  Read_Addr_1,
    input  logic [4:0]  Read_Addr_2,

    // 32bit data
    input  logic [31:0] Data_In,
    output logic [31:0] Data_Out_1,
    output logic [31:0] Data_Out_2
);

    // 32 registers with 32 bits
    logic [31:0] regfile [0:31];

    always_ff @(posedge Clock) begin
        if (Write_Enable) begin
            regfile[Write_Addr] <= Data_In;
        end
    end

    // asynchronous read out
    assign Data_Out_1 = (Read_Addr_1 == 5'd0) ? 32'd0 : regfile[Read_Addr_1];
    assign Data_Out_2 = (Read_Addr_2 == 5'd0) ? 32'd0 : regfile[Read_Addr_2];

endmodule
`default_nettype wire
