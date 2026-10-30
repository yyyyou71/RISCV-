`default_nettype none
// Hardware boundary: signed (16x8)+(16x8), 25-bit, 3 enabled pipeline stages.
// Generate pango_ai_multadd in PDS before enabling the board AI configuration.
module multiply_adder_w8a16 (
    input wire [15:0] a0,a1,
    input wire [7:0] b0,b1,
    input wire clk,rst,ce,addsub,
    output wire [24:0] p
);
    pango_ai_multadd u_ip (.a0(a0),.a1(a1),.b0(b0),.b1(b1),
        .clk(clk),.rst(rst),.ce(ce),.addsub(addsub),.p(p));
endmodule
`default_nettype wire
