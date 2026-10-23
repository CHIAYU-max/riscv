// top_processor.v
module top_processor (
    input wire Clock,
    input wire rst,
    input wire start 
);

    // inner wires
    wire [31:0] rf_data_1, rf_data_2, alu_result;
    wire alu_zero_flag;
    
    // control signals
    reg [4:0]  ctrl_rd_addr_1, ctrl_rd_addr_2, ctrl_wr_addr;
    reg        ctrl_wr_en;
    reg [1:0]  ctrl_opcode;

    // Register File instantiation 
    regfile_32x32_2r my_rf (
        .Clock       (Clock),
        .rst         (rst),
        .Write_Enable(ctrl_wr_en),
        .Write_Addr  (ctrl_wr_addr),
        .Read_Addr_1 (ctrl_rd_addr_1),
        .Read_Addr_2 (ctrl_rd_addr_2),
        .Data_In     (alu_result),   
        .Data_Out_1  (rf_data_1),
        .Data_Out_2  (rf_data_2)
    );

    // ALU instantiation 
    simple_alu my_alu (
        .A           (rf_data_1),
        .B           (rf_data_2),
        .opcode      (ctrl_opcode),
        .Data_out    (alu_result),
        .Alu_Zero    (alu_zero_flag)
    );

    // define opcode
    localparam IDLE   = 2'd0; // waiting for start signal
    localparam DECODE = 2'd1; // get register address and set opcode
    localparam COUNT  = 2'd2; // calculate the value counting right now
    localparam ADD    = 2'd3; // add the counting value right now to sum

    reg [1:0] current_state, next_state;

    // reset state
    always @(posedge Clock) begin
        if (rst) current_state <= IDLE;
        else     current_state <= next_state;
    end

    // initial value
    always @(*) begin
        ctrl_wr_en     = 0;
        ctrl_opcode    = 2'b00;
        ctrl_rd_addr_1 = 5'd0;
        ctrl_rd_addr_2 = 5'd0;
        ctrl_wr_addr   = 5'd0;
        next_state     = current_state;

        case (current_state)
            IDLE: begin
                if (start) next_state = DECODE;
            end

            DECODE: begin
                // R3 = R1 + R2
                ctrl_rd_addr_1 = 5'd1;  // register 1
                ctrl_rd_addr_2 = 5'd2;  // register2
                ctrl_opcode    = 2'b00; // set add mode
                next_state     = COUNT;
            end

            COUNT: begin
                ctrl_rd_addr_1 = 5'd1;  
                ctrl_rd_addr_2 = 5'd2;  
                ctrl_opcode    = 2'b00;

                ctrl_wr_addr   = 5'd2;  // add 1 to the current count number 
                ctrl_wr_en     = 1'b1;
                next_state     = ADD; 
            end

            ADD: begin
                ctrl_rd_addr_1 = 5'd3;
                ctrl_rd_addr_2 = 5'd2;
                ctrl_opcode    = 2'b00;

                ctrl_wr_addr   = 5'd3; //add the counting number to the sum
                ctrl_wr_en     = 1'b1;
                if (rf_data_2 == 32'd10) 
                    next_state = IDLE;
                else
                    next_state = COUNT;
            end 
            
            default: next_state = IDLE;
        endcase
    end

endmodule