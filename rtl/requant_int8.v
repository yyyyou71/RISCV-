`timescale 1ns/1ps
`default_nettype none
// 单路输出重定标：INT64 累加值 × 非负 31 位整数 / 2^shift。
// 绝对值域中四舍五入，恰好半整数时远离零；随后可选 ReLU，饱和到 INT8。
// 乘积完整保留 96 位，不能先截成 INT64。输出握手前保持结果。
module requant_int8 (
    input wire clk, rst_n,
    input wire in_valid, output wire in_ready,
    input wire signed [63:0] in_sum,
    input wire [31:0] multiplier, shift,
    input wire relu,
    output wire out_valid, input wire out_ready,
    output reg [7:0] out_data,
    output reg out_error
);
    localparam [1:0] IDLE=0, ROUND=1, RESULT=2;
    reg [1:0] state;
    reg [95:0] product;
    reg negative, relu_reg, invalid;
    reg [6:0] shift_reg;
    wire [63:0] magnitude=in_sum[63] ? (~$unsigned(in_sum)+64'd1) : $unsigned(in_sum);
    wire [95:0] shifted=product>>shift_reg;
    wire round_up=(shift_reg!=0) && product[shift_reg-7'd1];
    wire [95:0] rounded=shifted+{{95{1'b0}},round_up};
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; product<=0; negative<=0; relu_reg<=0; invalid<=0;
            shift_reg<=0; out_data<=0; out_error<=0;
        end else case(state)
            IDLE: if(in_valid && in_ready) begin
                product<=magnitude*multiplier;
                negative<=in_sum[63]; relu_reg<=relu;
                invalid<=multiplier[31] || shift>95;
                shift_reg<=shift<=95 ? shift[6:0] : 7'd0;
                state<=ROUND;
            end
            ROUND: begin
                out_error<=invalid;
                if(invalid || (relu_reg && negative)) out_data<=0;
                else if(negative) out_data<=rounded>=96'd128 ? 8'h80 : (~rounded[7:0]+8'd1);
                else out_data<=rounded>96'd127 ? 8'h7f : rounded[7:0];
                state<=RESULT;
            end
            RESULT: if(out_valid && out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
