// Unified instruction / data memory for Basys3.
// Two asynchronous read ports and one synchronous write port with byte enables,
// matching the rv32i_core port contract (README "Core interface").
// Vivado maps asynchronous reads to distributed RAM (LUTs), so keep it small:
// 2048 words = 8 KiB uses about a quarter of the XC7A35T's distributed RAM per read port.
module fpga_mem #(
    parameter WORDS     = 2048,
    parameter AW        = 11,           // log2(WORDS)
    parameter INIT_FILE = ""            // $readmemh image, one 32-bit word per line
) (
    input  wire        clk,
    input  wire [31:0] iaddr,
    output wire [31:0] irdata,
    input  wire [31:0] daddr,
    input  wire [31:0] dwdata,
    input  wire [3:0]  dwstrb,          // already qualified: no write outside RAM
    output wire [31:0] drdata
);

    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    assign irdata = mem[iaddr[AW+1:2]];
    assign drdata = mem[daddr[AW+1:2]];

    always @(posedge clk) begin
        if (dwstrb[0]) mem[daddr[AW+1:2]][7:0]   <= dwdata[7:0];
        if (dwstrb[1]) mem[daddr[AW+1:2]][15:8]  <= dwdata[15:8];
        if (dwstrb[2]) mem[daddr[AW+1:2]][23:16] <= dwdata[23:16];
        if (dwstrb[3]) mem[daddr[AW+1:2]][31:24] <= dwdata[31:24];
    end

endmodule
