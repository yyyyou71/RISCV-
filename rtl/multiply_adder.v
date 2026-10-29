`default_nettype none
// Legacy W8A8 boundary, retained only for format rejection/regression builds.
module multiply_adder #(
    parameter integer A_WIDTH=8,B_WIDTH=8,A_SIGNED=1,B_SIGNED=1,
    parameter integer PIPE_STAGES=3,ASYNC_RESET=0,STATIC_SUBTRACT=0
)(
    input wire [A_WIDTH-1:0] a0,a1,
    input wire [B_WIDTH-1:0] b0,b1,
    input wire clk,rst,ce,addsub,
    output wire [A_WIDTH+B_WIDTH:0] p
);
    pango_ai_multadd8 u_ip (.a0(a0),.a1(a1),.b0(b0),.b1(b1),
        .clk(clk),.rst(rst),.ce(ce),.addsub(addsub),.p(p));
    // synthesis translate_off
    initial if(A_WIDTH!=8 || B_WIDTH!=8 || A_SIGNED!=1 || B_SIGNED!=1 ||
        PIPE_STAGES!=3 || ASYNC_RESET!=0 || STATIC_SUBTRACT!=0)
        $fatal(1,"Hardware W8A8 IP configuration mismatch");
    // synthesis translate_on
endmodule
`default_nettype wire
