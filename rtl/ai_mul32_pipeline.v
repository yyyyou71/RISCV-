`default_nettype none
// Exact unsigned 32x32 product, four register stages. Four 16x16 multipliers
// avoid a long unregistered cascade across_sum DSP blocks.
module ai_mul32_pipeline(
    input wire clk,rst_n,clear,in_valid,
    input wire [31:0] a,b,
    output wire out_valid,
    output wire [63:0] product
);
    reg [3:0] valid;
    reg [31:0] p00,p01,p10,p11,h1,h2;
    reg [32:0] cross_sum;
    reg [33:0] middle;
    reg [15:0] lo1,lo2,lo3,mid3,carry1;
    reg [31:0] high3;
    assign out_valid=valid[3];
    assign product={high3,mid3,lo3};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            valid<=0;p00<=0;p01<=0;p10<=0;p11<=0;cross_sum<=0;middle<=0;
            h1<=0;h2<=0;lo1<=0;lo2<=0;lo3<=0;mid3<=0;high3<=0;carry1<=0;
        end else begin
            valid<=clear ? 4'b0 : {valid[2:0],in_valid};
            p00<=a[15:0]*b[15:0];p01<=a[15:0]*b[31:16];
            p10<=a[31:16]*b[15:0];p11<=a[31:16]*b[31:16];
            cross_sum<={1'b0,p01}+{1'b0,p10};lo1<=p00[15:0];h1<=p11;carry1<=p00[31:16];
            middle<={1'b0,cross_sum}+{18'b0,carry1};
            lo2<=lo1;h2<=h1;
            high3<=h2+{14'b0,middle[33:16]};mid3<=middle[15:0];lo3<=lo2;
        end
    end
endmodule
`default_nettype wire
