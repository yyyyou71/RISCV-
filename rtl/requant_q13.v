`timescale 1ns/1ps
`default_nettype none
// Exact Q13 arithmetic, split multiplication/round/shift/sum/bias/clamp stages.
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
    localparam [3:0] IDLE=0,M0_START=1,M0_WAIT=2,M1_START=3,M1_WAIT=4,
        ROUND=5,SHIFT=6,SUM=7,BIAS=8,CLAMP=9,Y_START=10,Y_WAIT=11,
        Y_ROUND=12,Y_SHIFT=13,FINAL=14,RESULT=15;
    reg [3:0] state;
    reg signed [63:0] sum0_reg,sum1_reg;
    reg [30:0] m0_reg,m1_reg,my_reg;
    reg signed [31:0] bias_reg,activated;
    reg [6:0] s0,s1,sy;
    reg group_reg,relu_reg,invalid;
    reg signed [95:0] p0,p1,py,round0,round1,roundy,q0,q1,qsum,q13,final_value;
    reg signed [95:0] half0,half1,halfy;
    wire mul_start=state==M0_START || state==M1_START || state==Y_START;
    wire mul_valid;
    wire signed [95:0] mul_result;
    wire signed [63:0] mul_value=state==Y_START?{{32{activated[31]}},activated}:state==M1_START?sum1_reg:sum0_reg;
    wire [30:0] mul_factor=state==Y_START?my_reg:state==M1_START?m1_reg:m0_reg;
    scale_mul64x31 u_scale_mul(.clk(clk),.rst_n(rst_n),.in_valid(mul_start),.in_ready(),
        .value(mul_value),.multiplier(mul_factor),.out_valid(mul_valid),.out_ready(1'b1),.result(mul_result));
    function signed [95:0] half;
        input [31:0] amount;
        begin half=amount==0 || amount>95?96'sd0:(96'sd1<<(amount[6:0]-7'd1));end
    endfunction
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;sum0_reg<=0;sum1_reg<=0;m0_reg<=0;m1_reg<=0;my_reg<=0;
            bias_reg<=0;activated<=0;s0<=0;s1<=0;sy<=0;group_reg<=0;relu_reg<=0;invalid<=0;
            p0<=0;p1<=0;py<=0;round0<=0;round1<=0;roundy<=0;q0<=0;q1<=0;qsum<=0;q13<=0;final_value<=0;
            half0<=0;half1<=0;halfy<=0;out_data<=0;out_error<=0;out_clamped<=0;
        end else case(state)
            IDLE:if(in_valid)begin
                sum0_reg<=in_sum0;sum1_reg<=in_sum1;m0_reg<=mult_m0[30:0];m1_reg<=mult_m1[30:0];my_reg<=mult_y[30:0];
                bias_reg<=bias_q13;group_reg<=group1_enable;relu_reg<=relu;p1<=0;
                s0<=shift_m0<=95?shift_m0[6:0]:7'd0;s1<=shift_m1<=95?shift_m1[6:0]:7'd0;
                sy<=shift_y<=95?shift_y[6:0]:7'd0;half0<=half(shift_m0);half1<=half(shift_m1);halfy<=half(shift_y);
                invalid<=mult_m0[31] || mult_y[31] || shift_m0>95 || shift_y>95 ||
                    (group1_enable && (mult_m1[31] || shift_m1>95));
                state<=M0_START;
            end
            M0_START:state<=M0_WAIT;
            M0_WAIT:if(mul_valid)begin p0<=mul_result;state<=group_reg?M1_START:ROUND;end
            M1_START:state<=M1_WAIT;
            M1_WAIT:if(mul_valid)begin p1<=mul_result;state<=ROUND;end
            ROUND:begin round0<=p0+half0;round1<=p1+half1;state<=SHIFT;end
            SHIFT:begin q0<=round0>>>s0;q1<=round1>>>s1;state<=SUM;end
            SUM:begin qsum<=q0+q1;state<=BIAS;end
            BIAS:begin q13<=qsum+{{64{bias_reg[31]}},bias_reg};state<=CLAMP;end
            CLAMP:begin
                out_clamped<=!invalid && (q13>96'sd2147483647 || q13< -96'sd2147483648);
                if(relu_reg && q13<0)activated<=0;
                else if(q13>96'sd2147483647)activated<=32'sh7fffffff;
                else if(q13< -96'sd2147483648)activated<=32'sh80000000;
                else activated<=q13[31:0];
                state<=Y_START;
            end
            Y_START:state<=Y_WAIT;
            Y_WAIT:if(mul_valid)begin py<=mul_result;state<=Y_ROUND;end
            Y_ROUND:begin roundy<=py+halfy;state<=Y_SHIFT;end
            Y_SHIFT:begin final_value<=roundy>>>sy;state<=FINAL;end
            FINAL:begin
                out_error<=invalid;out_data<=invalid ? 16'd0 : final_value>96'sd32767 ? 16'h7fff :
                    final_value< -96'sd32767 ? 16'h8001 : final_value[15:0];state<=RESULT;
            end
            RESULT:if(out_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
