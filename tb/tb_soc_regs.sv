// Self-check of the generated register block (build/regs/soc_regs.sv from sw/regs/regs.json): SCRATCH reads back
// what was written and resets to 0, read-only registers return their hardware inputs, CTRL.start / clear give
// one-cycle pulses only on a write of 1, and an unused offset reads 0. Run with make regs-test.
module tb_soc_regs;
  logic clk = 0, rst_n = 0;
  logic req_valid = 0, req_we = 0;
  logic [3:0] req_addr = '0;
  logic [31:0] req_wdata = '0, rdata;
  logic start, clear, busy = 0, done = 0;
  logic [31:0] cyc_lo = 32'h1234_5678, cyc_hi = 32'h0000_0009, ev_dot4 = 32'd42, ev_load = 32'd7, ev_store = 32'd3;
  logic [31:0] ev_wait = 32'd11, crc = 32'hdead_beef, scratch;
  int errors = 0, start_pulses = 0, clear_pulses = 0;

  soc_regs dut (
    .clk_i(clk), .rst_ni(rst_n), .req_valid_i(req_valid), .req_we_i(req_we), .req_addr_i(req_addr),
    .req_wdata_i(req_wdata), .rdata_o(rdata),
    .ctrl_start_o(start), .ctrl_clear_o(clear), .status_busy_i(busy), .status_done_i(done),
    .cycle_lo_value_i(cyc_lo), .cycle_hi_value_i(cyc_hi), .ev_dot4_value_i(ev_dot4), .ev_load_value_i(ev_load),
    .ev_store_value_i(ev_store), .ev_bus_wait_value_i(ev_wait), .retire_sig_crc_i(crc), .scratch_value_q_o(scratch)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    if (start) start_pulses++;
    if (clear) clear_pulses++;
  end

  task automatic write(input logic [3:0] a, input logic [31:0] d);
    @(negedge clk); req_valid = 1; req_we = 1; req_addr = a; req_wdata = d;
    @(negedge clk); req_valid = 0; req_we = 0;
  endtask

  task automatic expect_read(input logic [3:0] a, input logic [31:0] want, input string what);
    @(negedge clk); req_valid = 1; req_we = 0; req_addr = a;
    @(negedge clk); req_valid = 0;
    if (rdata !== want) begin
      $display("FAIL %s: read %08h, expected %08h", what, rdata, want);
      errors++;
    end
  endtask

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;
    expect_read(4'd9, 32'h0, "SCRATCH after reset");
    write(4'd9, 32'hcafe_f00d);
    expect_read(4'd9, 32'hcafe_f00d, "SCRATCH read back");
    if (scratch !== 32'hcafe_f00d) begin $display("FAIL SCRATCH output"); errors++; end
    busy = 1; done = 0;
    expect_read(4'd1, 32'h1, "STATUS busy");
    busy = 0; done = 1;
    expect_read(4'd1, 32'h2, "STATUS done");
    expect_read(4'd2, cyc_lo, "CYCLE_LO");
    expect_read(4'd3, cyc_hi, "CYCLE_HI");
    expect_read(4'd4, ev_dot4, "EV_DOT4");
    expect_read(4'd5, ev_load, "EV_LOAD");
    expect_read(4'd6, ev_store, "EV_STORE");
    expect_read(4'd7, ev_wait, "EV_BUS_WAIT");
    expect_read(4'd8, crc, "RETIRE_SIG");
    expect_read(4'd0, 32'h0, "CTRL reads 0");
    expect_read(4'd15, 32'h0, "unused offset");
    write(4'd0, 32'h1);
    write(4'd0, 32'h2);
    write(4'd0, 32'h0);
    if (start_pulses != 1 || clear_pulses != 1) begin
      $display("FAIL CTRL pulses: start %0d, clear %0d (expected 1, 1)", start_pulses, clear_pulses);
      errors++;
    end
    if (errors == 0) $display("PASS    soc_regs");
    else $display("FAIL    soc_regs: %0d errors", errors);
    $finish;
  end
endmodule
