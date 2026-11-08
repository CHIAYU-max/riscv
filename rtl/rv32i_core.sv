`default_nettype none
module rv32i_core import rv_pkg::*;(
    input   logic        clk,
    input   logic        rst,
    input   logic[31:0]  imem_rdata,
    input   logic[31:0]  dmem_rdata,

    output  logic[31:0]  imem_addr,
    output  logic[31:0]  dmem_addr,
    output  logic[31:0]  dmem_wdata,
    output  logic[3:0]   dmem_wstrb
);
            logic[2:0]  funct3;
            logic[4:0]  rd, rs1, rs2;
            logic[6:0]  opcode, funct7;
            logic[31:0] pc, next_pc;
            ctrl_t      ctrl;

    assign  next_pc     =   pc + 4;
    assign  imem_addr   =   pc;
    assign  dmem_addr   =   32'b0;
    assign  dmem_wdata  =   32'b0;
    assign  dmem_wstrb  =   4'b0;
    assign  opcode      =   imem_rdata[6:0];
    assign  rd          =   imem_rdata[11:7];
    assign  funct3      =   imem_rdata[14:12];
    assign  rs1         =   imem_rdata[19:15];
    assign  rs2         =   imem_rdata[24:20];
    assign  funct7      =   imem_rdata[31:25];

    pc_reg u_pc(
        .clk        (clk),
        .rst        (rst),
        .pc         (pc),
        .next_pc    (next_pc)
    );

    decoder u_decoder(
        .opcode     (opcode),
        .funct3     (funct3),
        .funct7     (funct7),
        .ctrl       (ctrl)
    );

endmodule

`default_nettype wire
