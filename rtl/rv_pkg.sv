package rv_pkg;

    //opcode
    localparam  logic[6:0]  LUI     =   7'b0110111;
    localparam  logic[6:0]  LOAD    =   7'b0000011;
    localparam  logic[6:0]  AUIPC   =   7'b0010111;
    localparam  logic[6:0]  JAL     =   7'b1101111;
    localparam  logic[6:0]  JALR    =   7'b1100111;
    localparam  logic[6:0]  BRANCH  =   7'b1100011;
    localparam  logic[6:0]  STORE   =   7'b0100011;
    localparam  logic[6:0]  OP_IMM  =   7'b0010011;
    localparam  logic[6:0]  OP      =   7'b0110011;
    localparam  logic[6:0]  MISC_MEM=   7'b0001111;
    localparam  logic[6:0]  CUSTOM_0=   7'b0001011;

    typedef enum logic[2:0]{
        IMM_I,
        IMM_U,
        IMM_J,
        IMM_S,
        IMM_B
    }   imm_type_t;

    typedef enum logic[1:0]{
        SRC_A_ZERO,
        SRC_A_PC,
        SRC_A_RS1
    }   alu_src_a_t;

    typedef enum logic{
        SRC_B_IMM,
        SRC_B_RS2
    }   alu_src_b_t;

    typedef enum logic[3:0]{
        ALU_ADD,
        ALU_SUB,
        ALU_SLL,
        ALU_SLT,
        ALU_SLTU,
        ALU_XOR,
        ALU_SRL,
        ALU_SRA,
        ALU_OR,
        ALU_AND
    }   alu_op_t;

    typedef enum logic[1:0]{
        WB_ZERO,
        WB_ALU,
        WB_PC4
    }   wb_sel_t;

    typedef struct packed{
        logic       reg_write;
        logic       mem_write;
        logic       jump;
        imm_type_t  imm_type;
        alu_src_a_t alu_src_a;
        alu_src_b_t alu_src_b;
        alu_op_t    alu_op;
        wb_sel_t    wb_sel;
    }   ctrl_t;
endpackage
