// Shows a 4 * DIGITS-bit value as DIGITS hex digits on a common-anode 7-segment display
// (Basys3: 4 digits, Nexys A7: 8 digits). Digit scan as in lab5-1's Seven_Seg_Scan (one active-low
// anode at a time); one full scan takes 2^REFRESH_BITS clock cycles, whatever DIGITS is.
module seg7_hex #(
    parameter DIGITS       = 4,         // 4 or 8 (a power of two)
    parameter REFRESH_BITS = 18         // 25 MHz: about 95 Hz per full scan
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire [4*DIGITS-1:0]   value,
    output reg  [6:0]            seg,   // {g, f, e, d, c, b, a}, active low (seg[0] = CA)
    output reg  [DIGITS-1:0]     an     // active low, an[0] = rightmost digit
);

    localparam SW = $clog2(DIGITS);

    reg  [REFRESH_BITS-1:0] refresh;
    wire [SW-1:0]           sel = refresh[REFRESH_BITS-1 -: SW];
    reg  [3:0]              digit;

    always @(posedge clk) begin
        if (rst) refresh <= 0;
        else refresh <= refresh + 1'b1;
    end

    always @(*) begin
        an    = ~({{(DIGITS-1){1'b0}}, 1'b1} << sel);
        digit = value[4*sel +: 4];
    end

    always @(*) begin
        case (digit)            // gfedcba, 0 = segment on
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            default: seg = 7'b0001110;  // F
        endcase
    end

endmodule
