`timescale 1ns/1ps
`default_nettype none
// 两路特征值分别缩放、RHU舍入，再相加并饱和；对应参考C的add_point。
// 与卷积不同：没有Q13偏置、没有ReLU，也不在两路相加前截成INT16。
// 单路计算器分时处理DDR字中的8个元素，不增加卷积MAC并行规模。
module add_int16 (
    input wire clk,rst_n,
    input wire in_valid,output wire in_ready,
    input wire signed [15:0] in_a,in_b,
    input wire [31:0] mult_a,shift_a,mult_b,shift_b,
    output wire out_valid,input wire out_ready,
    output reg [15:0] out_data,
    output reg out_error
);
    localparam [1:0] IDLE=0,SCALE=1,RESULT=2;
    reg [1:0] state;
    reg signed [63:0] product_a,product_b;
    reg [5:0] sa,sb;
    reg invalid;
    function signed [63:0] rhu;
        input signed [63:0] value;
        input [5:0] shift;
        begin rhu=shift==0 ? value:(value+($signed(64'd1)<<(shift-6'd1)))>>>shift;end
    endfunction
    wire signed [63:0] sum=rhu(product_a,sa)+rhu(product_b,sb);
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;product_a<=0;product_b<=0;sa<=0;sb<=0;invalid<=0;out_data<=0;out_error<=0;
        end else case(state)
            IDLE:if(in_valid && in_ready)begin
                product_a<=$signed(in_a)*$signed({1'b0,mult_a});
                product_b<=$signed(in_b)*$signed({1'b0,mult_b});
                sa<=shift_a<=63 ? shift_a[5:0]:6'd0;sb<=shift_b<=63 ? shift_b[5:0]:6'd0;
                invalid<=mult_a[31] || mult_b[31] || shift_a>63 || shift_b>63;
                state<=SCALE;
            end
            SCALE:begin
                out_error<=invalid;
                out_data<=invalid ? 16'd0:sum>64'sd32767 ? 16'h7fff:sum< -64'sd32767 ? 16'h8001:sum[15:0];
                state<=RESULT;
            end
            RESULT:if(out_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
