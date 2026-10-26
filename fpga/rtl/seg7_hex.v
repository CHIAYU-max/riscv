// Shows a 16-bit value as 4 hex digits on the Basys3 7-segment display.
// Digit scan as in lab5-1's Seven_Seg_Scan (one active-low anode at a time);
// each digit is lit for 2^REFRESH_BITS / 4 clock cycles.
module seg7_hex #(
    parameter REFRESH_BITS = 18         // 25 MHz: about 95 Hz per full scan
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] value,
    output reg  [6:0]  seg,             // {g, f, e, d, c, b, a}, active low (seg[0] = CA)
    output reg  [3:0]  an               // active low, an[0] = rightmost digit
);

    reg  [REFRESH_BITS-1:0] refresh;
    wire [1:0]              sel = refresh[REFRESH_BITS-1:REFRESH_BITS-2];
    reg  [3:0]              digit;

    always @(posedge clk) begin
        if (rst) refresh <= 0;
        else refresh <= refresh + 1'b1;
    end

    always @(*) begin
        case (sel)
            2'd0: begin an = 4'b1110; digit = value[3:0];   end
            2'd1: begin an = 4'b1101; digit = value[7:4];   end
            2'd2: begin an = 4'b1011; digit = value[11:8];  end
            default: begin an = 4'b0111; digit = value[15:12]; end
        endcase
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
