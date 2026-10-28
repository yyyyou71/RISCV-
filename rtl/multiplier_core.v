module multiplier_core #(
    parameter integer PIPE_STAGES = 3
) (
    input wire clk,
    input wire rst,
    input wire ce,
    input wire signed [32:0] a,
    input wire signed [32:0] b,
    output wire signed [65:0] p
);
    pango_multiplier_ip u_ip (
        .clk(clk), .rst(rst), .ce(ce), .a(a), .b(b), .p(p)
    );

`ifndef SYNTHESIS
    initial begin
        if (PIPE_STAGES != 3)
            $fatal(1, "pango_multiplier_ip is generated for exactly three pipeline stages");
    end
`endif
endmodule
