`default_nettype none
module simple_alu (
    input  logic [31:0] A,          // register 1
    input  logic [31:0] B,          // register2
    input  logic [1:0]  opcode,     // decide operation
    output logic [31:0] Data_out,   // calculation results
    output logic        Alu_Zero    // Zero Flag
);

    // define opcode
    localparam OP_ADD = 2'b00;
    localparam OP_MUL = 2'b01;
    localparam OP_SUB = 2'b10;
    localparam OP_AND = 2'b11;

    // define opcode behavior
    always_comb begin
        case (opcode)
            OP_ADD: Data_out = A + B;
            OP_MUL: Data_out = A * B;
            OP_SUB: Data_out = A - B;
            OP_AND: Data_out = A & B;
            default: Data_out = 32'h0000_0000;
        endcase
    end

    // when the output = 0
    assign Alu_Zero = (Data_out == 32'h0000_0000) ? 1'b1 : 1'b0;

endmodule
`default_nettype wire

