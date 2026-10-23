// regfile_32x32_2r.v
module regfile_32x32_2r (
    input  wire        Clock,          
    input  wire        rst,            
    input  wire        Write_Enable,
    
    // 5bit address 
    input  wire [4:0]  Write_Addr,     
    input  wire [4:0]  Read_Addr_1,    
    input  wire [4:0]  Read_Addr_2,    
    
    // 32bit data 
    input  wire [31:0] Data_In,        
    output wire [31:0] Data_Out_1,     
    output wire [31:0] Data_Out_2      
);

    // 32 registers with 32 bits
    reg [31:0] regfile [0:31];
    integer i;

    // sync write and reset
    always @(posedge Clock) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                regfile[i] <= 32'h0000_0000; // 32-bit 歸零
        end else if (Write_Enable) begin
            regfile[Write_Addr] <= Data_In;
        end
    end

    // asynchronous read out
    assign Data_Out_1 = regfile[Read_Addr_1];
    assign Data_Out_2 = regfile[Read_Addr_2];

endmodule