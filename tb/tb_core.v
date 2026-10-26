`timescale 1ns / 1ps
// Testbench for rv32i_core (SystemVerilog strings; compile with iverilog -g2012): runs one program and reports PASS / FAIL / TIMEOUT.
//
//   vvp build/sim_core +HEX=build/tests/add.hex +NAME=add [+VCD] [+MAX_CYCLES=n]
//
// Memory: 64 KiB RAM at 0x0000_0000 holding code and data (loaded from +HEX, one
// 32-bit word per line). Instruction and data ports read the same array
// asynchronously, so self-modifying code is visible to instruction fetch.
// A store to TOHOST (0x8000_0000) ends the run: 1 = pass, (n << 1) | 1 = fail in test n.
// See README.md ("Core interface") for the port contract.
module tb_core;

    localparam MEM_WORDS = 16384;  // 64 KiB
    localparam AW        = 14;     // word address bits
    localparam TOHOST    = 32'h8000_0000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [31:0] mem [0:MEM_WORDS-1];

    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire [31:0] dmem_rdata;

    rv32i_core dut (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_rdata (dmem_rdata)
    );

    wire imem_in_ram = (imem_addr >> (AW + 2)) == 0;
    wire dmem_in_ram = (dmem_addr >> (AW + 2)) == 0;

    assign imem_rdata = imem_in_ram ? mem[imem_addr[AW+1:2]] : 32'h0000_0000;
    assign dmem_rdata = dmem_in_ram ? mem[dmem_addr[AW+1:2]] : 32'h0000_0000;

    string  name;
    string  hex;
    integer max_cycles;
    integer cycles;
    integer i;

    task finish_with(input string result, input integer detail);
        begin
            if (result == "PASS")
                $display("PASS    %0s (%0d cycles)", name, cycles);
            else if (result == "FAIL")
                $display("FAIL    %0s: test case %0d (%0d cycles)", name, detail, cycles);
            else
                $display("%0s %0s: pc 0x%08h (%0d cycles)", result, name, imem_addr, cycles);
            $finish;
        end
    endtask

    initial begin
        if (!$value$plusargs("NAME=%s", name)) name = "program";
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100000;
        if (!$value$plusargs("HEX=%s", hex)) begin
            $display("ERROR   no program: pass +HEX=<file>");
            $finish;
        end
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'h0000_0000;
        $readmemh(hex, mem);
        if ($test$plusargs("VCD")) begin
            $dumpfile({"build/", name, ".vcd"});
            $dumpvars(0, tb_core);
        end
        cycles = 0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if (cycles >= max_cycles)
                finish_with("TIMEOUT", 0);
            if (|dmem_wstrb) begin
                if (dmem_addr == TOHOST) begin
                    if (dmem_wdata == 32'd1)
                        finish_with("PASS", 0);
                    else
                        finish_with("FAIL", dmem_wdata >> 1);
                end else if (dmem_in_ram) begin
                    if (dmem_wstrb[0]) mem[dmem_addr[AW+1:2]][7:0]   <= dmem_wdata[7:0];
                    if (dmem_wstrb[1]) mem[dmem_addr[AW+1:2]][15:8]  <= dmem_wdata[15:8];
                    if (dmem_wstrb[2]) mem[dmem_addr[AW+1:2]][23:16] <= dmem_wdata[23:16];
                    if (dmem_wstrb[3]) mem[dmem_addr[AW+1:2]][31:24] <= dmem_wdata[31:24];
                end else begin
                    $display("ERROR   %0s: store to unmapped address 0x%08h", name, dmem_addr);
                    finish_with("BADADDR", 0);
                end
            end
        end
    end

endmodule
