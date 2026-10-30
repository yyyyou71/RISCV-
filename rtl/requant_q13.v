`timescale 1ns/1ps
`default_nettype none
// 对应参考 C 的两级量化：各尺度组分别舍入到 Q13，再相加、加偏置、钳位、ReLU。
// 最后重定标到对称 INT16 [-32767,32767]。RHU 的负半整数朝正方向舍入。
// multiplier 为非负 31 位整数，shift 为 0..95；不支持左移型量化参数。
// 96 位有符号中间乘积保留 INT64xINT32 精度；参数随输入握手锁存。
module requant_q13 (
    input wire clk, rst_n,
    input wire in_valid, output wire in_ready,
    input wire signed [63:0] in_sum0, in_sum1,
    input wire group1_enable,
    input wire [31:0] mult_m0, shift_m0, mult_m1, shift_m1,
    input wire signed [31:0] bias_q13,
    input wire [31:0] mult_y, shift_y,
    input wire relu,
    output wire out_valid, input wire out_ready,
    output reg [15:0] out_data,
    output reg out_error, out_clamped
);
    localparam [1:0] IDLE=0, GROUP_SCALE=1, FINAL_SCALE=2, RESULT=3;
    reg [1:0] state;
    reg signed [95:0] product0, product1, product_y;
    reg signed [31:0] bias_reg;
    reg [31:0] mult_y_reg;
    reg [6:0] shift0_reg, shift1_reg, shift_y_reg;
    reg relu_reg, invalid;
    function signed [95:0] rhu;
        input signed [95:0] value;
        input [6:0] amount;
        begin
            rhu=amount==0 ? value : (value+($signed(96'd1)<<(amount-7'd1)))>>>amount;
        end
    endfunction
    wire signed [95:0] q13=rhu(product0,shift0_reg)+rhu(product1,shift1_reg)+{{64{bias_reg[31]}},bias_reg};
    wire clamped=q13>96'sd2147483647 || q13< -96'sd2147483648;
    wire signed [31:0] limited=q13>96'sd2147483647 ? 32'sh7fffffff :
        q13< -96'sd2147483648 ? 32'sh80000000 : q13[31:0];
    wire signed [31:0] activated=relu_reg && limited[31] ? 32'sd0 : limited;
    wire signed [95:0] final_value=rhu(product_y,shift_y_reg);
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; product0<=0; product1<=0; product_y<=0; bias_reg<=0;
            mult_y_reg<=0; shift0_reg<=0; shift1_reg<=0; shift_y_reg<=0;
            relu_reg<=0; invalid<=0; out_data<=0; out_error<=0; out_clamped<=0;
        end else case(state)
            IDLE: if(in_valid && in_ready) begin
                product0<=$signed(in_sum0)*$signed({1'b0,mult_m0});
                product1<=group1_enable ? $signed(in_sum1)*$signed({1'b0,mult_m1}) : 96'sd0;
                bias_reg<=bias_q13; mult_y_reg<=mult_y; relu_reg<=relu;
                shift0_reg<=shift_m0<=95 ? shift_m0[6:0] : 7'd0;
                shift1_reg<=shift_m1<=95 ? shift_m1[6:0] : 7'd0;
                shift_y_reg<=shift_y<=95 ? shift_y[6:0] : 7'd0;
                invalid<=mult_m0[31] || mult_y[31] || shift_m0>95 || shift_y>95 ||
                    (group1_enable && (mult_m1[31] || shift_m1>95));
                state<=GROUP_SCALE;
            end
            GROUP_SCALE: begin
                product_y<=$signed(activated)*$signed({1'b0,mult_y_reg});
                out_clamped<=!invalid && clamped;
                state<=FINAL_SCALE;
            end
            FINAL_SCALE: begin
                out_error<=invalid;
                out_data<=invalid ? 16'd0 : final_value>96'sd32767 ? 16'h7fff :
                    final_value< -96'sd32767 ? 16'h8001 : final_value[15:0];
                state<=RESULT;
            end
            RESULT: if(out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
