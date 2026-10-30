`timescale 1ns/1ps
`default_nettype none
// 固定有符号 16x8 的两项乘积求和，25 位结果，3 级同步复位流水。
// 这是厂商 IP 的替换边界：上板时用同名、同配置生成 IP 替换此文件。
// 不应把原 8x8 的 multiply_adder IP 直接改成 16x8，两条通路需要各自的配置。
module multiply_adder_w8a16 (
    input wire [15:0] a0, a1,
    input wire [7:0] b0, b1,
    input wire clk, rst, ce, addsub,
    output wire [24:0] p
);
    multiply_adder #(.A_WIDTH(16),.B_WIDTH(8)) u_model (
        .a0(a0),.a1(a1),.b0(b0),.b1(b1),
        .clk(clk),.rst(rst),.ce(ce),.addsub(addsub),.p(p)
    );
endmodule
`default_nettype wire
