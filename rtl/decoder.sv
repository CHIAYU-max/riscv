`default_nettype none
module decoder import rv_pkg::*;
(
    input   logic[6:0]   opcode, funct7,
    input   logic[2:0]   funct3,

    output  ctrl_t      ctrl
);

    always_comb begin
        ctrl    =   '0;

        case(opcode)
            OP:begin
            end

            OP_IMM:begin
                ctrl.imm_type    =   IMM_I;
                ctrl.reg_write   =   1'b1;
                ctrl.alu_src_a   =   SRC_A_RS1;
                ctrl.alu_src_b   =   SRC_B_IMM;
                ctrl.wb_sel      =   WB_ALU;

                case(funct3)
                    3'b000:begin
                        ctrl.alu_op =   ALU_ADD;
                    end
                    default:;
                endcase
            end

            STORE:begin
                ctrl.imm_type   =   IMM_S;
                ctrl.alu_src_a  =   SRC_A_RS1;
                ctrl.alu_src_b  =   SRC_B_IMM;
                ctrl.alu_op     =   ALU_ADD;
                ctrl.mem_write  =   1'b1;
                ctrl.wb_sel     =   WB_ZERO;
            end

            LUI:begin
                ctrl.imm_type   =   IMM_U;
                ctrl.reg_write  =   1'b1;
                ctrl.alu_src_a  =   SRC_A_ZERO;
                ctrl.alu_src_b  =   SRC_B_IMM;
                ctrl.alu_op     =   ALU_ADD;
                ctrl.wb_sel     =   WB_ALU;
            end

            JAL:begin
                ctrl.imm_type   =   IMM_J;
                ctrl.wb_sel     =   WB_PC4;
                ctrl.jump       =   1'b1;
            end
            default:;
        endcase
    end
endmodule

`default_nettype wire
