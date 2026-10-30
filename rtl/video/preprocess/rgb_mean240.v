`default_nettype none
// Exact mean of 240 unsigned pixels, rounded to nearest, ties to even.
// floor(sum/240) = floor((sum>>4)/15). For n in [0,4095],
// floor(n/15) == (n*2185)>>15; 2185 = 2048+128+8+1.
// Shift/add implementation avoids a variable divider and multiplier IP.
module rgb_mean240 (
    input wire clk,rst_n,clear,in_valid,
    input wire [15:0] sum_r,sum_g,sum_b,
    input wire [6:0] in_x,in_y,
    output reg out_valid,
    output reg [23:0] out_rgb,
    output reg [6:0] out_x,out_y,
    output wire busy
);
    reg v1,v2;
    reg [23:0] product_r,product_g,product_b;
    reg [15:0] saved_r,saved_g,saved_b,rem_r,rem_g,rem_b;
    reg [7:0] q_r,q_g,q_b;
    reg [6:0] x1,y1,x2,y2;
    function [23:0] reciprocal15;
        input [11:0] n;
        reg [23:0] wide;
        begin
            wide={12'b0,n};
            reciprocal15=((wide<<11)+(wide<<7))+((wide<<3)+wide);
        end
    endfunction
    function [15:0] times240;
        input [7:0] q;
        reg [15:0] wide;
        begin wide={8'b0,q};times240=(wide<<8)-(wide<<4);end
    endfunction
    function [7:0] rounded;
        input [7:0] q;
        input [15:0] remainder;
        begin rounded=q+{7'b0,(remainder>120 || (remainder==120 && q[0]))};end
    endfunction
    assign busy=v1|v2|out_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            v1<=0;v2<=0;out_valid<=0;out_rgb<=0;out_x<=0;out_y<=0;
            product_r<=0;product_g<=0;product_b<=0;saved_r<=0;saved_g<=0;saved_b<=0;
            rem_r<=0;rem_g<=0;rem_b<=0;q_r<=0;q_g<=0;q_b<=0;x1<=0;y1<=0;x2<=0;y2<=0;
        end else if(clear)begin v1<=0;v2<=0;out_valid<=0;end
        else begin
            v1<=in_valid;v2<=v1;out_valid<=v2;
            if(in_valid)begin
                product_r<=reciprocal15(sum_r[15:4]);product_g<=reciprocal15(sum_g[15:4]);
                product_b<=reciprocal15(sum_b[15:4]);saved_r<=sum_r;saved_g<=sum_g;saved_b<=sum_b;
                x1<=in_x;y1<=in_y;
            end
            if(v1)begin
                q_r<=product_r[22:15];q_g<=product_g[22:15];q_b<=product_b[22:15];
                rem_r<=saved_r-times240(product_r[22:15]);
                rem_g<=saved_g-times240(product_g[22:15]);
                rem_b<=saved_b-times240(product_b[22:15]);x2<=x1;y2<=y1;
            end
            if(v2)begin
                out_rgb<={rounded(q_r,rem_r),rounded(q_g,rem_g),rounded(q_b,rem_b)};
                out_x<=x2;out_y<=y2;
            end
        end
    end
endmodule
`default_nettype wire
