// Core clock for the 100 MHz boards (Basys3, Nexys A7): MMCM, VCO 1000 MHz, CLKOUT0 = CORE_MHZ.
// CORE_MHZ must divide 1000 into a step of 0.125 (25, 40, 50, 80, 100, ...).
module board_clk #(
    parameter CORE_MHZ = 25
) (
    input  wire clk_100m_i,
    output wire clk_core_o,
    output wire locked_o
);

    wire clk_fb, clk_core_unbuf;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .CLKFBOUT_MULT_F  (10.0),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F (1000.0 / CORE_MHZ)
    ) u_mmcm (
        .CLKIN1   (clk_100m_i),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_core_unbuf),
        .LOCKED   (locked_o),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3  (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .CLKFBOUTB()
    );

    BUFG u_bufg (.I(clk_core_unbuf), .O(clk_core_o));

endmodule
