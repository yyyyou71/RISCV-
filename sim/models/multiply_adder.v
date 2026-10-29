`timescale 1ns/1ps
`default_nettype none

// 《简单乘法器.pdf》UG041003 第 2.3、2.6.1 节的 Multiply-Adder 行为模型。
// 功能为 p = a0*b0 +/- a1*b1；这里没有跨拍反馈累加器。
// 支持静态加/减，关闭 Optimal Timing，流水线级数为 0..5。
// 默认目标：两组有符号 8x8、17 位输出、静态加法、3 级、同步高有效复位。
// addsub 按手册保留端口；本模型选择静态运算，因此不使用该引脚。
// 手册没有定义动态 addsub 与各级数据的逐拍对齐，本模型不模拟动态模式。
//
// 对全部有效配置：ce=0 保持所有流水级；rst 优先于 ce。
// PIPE_STAGES=0 时无寄存器，rst/ce 不影响组合输出。
// 流水线用结果队列作端口等效建模，不表示 APM 内部寄存器位置或资源映射。
// 上板请替换为同配置的厂商 IP，具体替换步骤见 docs/multiply_adder.md。
module multiply_adder #(
    parameter integer A_WIDTH = 8,
    parameter integer B_WIDTH = 8,
    parameter integer A_SIGNED = 1,
    parameter integer B_SIGNED = 1,
    parameter integer PIPE_STAGES = 3,
    parameter integer ASYNC_RESET = 0,
    parameter integer STATIC_SUBTRACT = 0
)(
    input  wire [A_WIDTH-1:0] a0,
    input  wire [A_WIDTH-1:0] a1,
    input  wire [B_WIDTH-1:0] b0,
    input  wire [B_WIDTH-1:0] b1,
    input  wire clk,
    input  wire rst,
    input  wire ce,
    input  wire addsub,
    output wire [A_WIDTH+B_WIDTH:0] p
);
    localparam integer P_WIDTH = A_WIDTH + B_WIDTH + 1;
    // 先根据端口类型扩展，再按有符号数运算；无符号输入额外补零。
    // P_WIDTH 足够保存每项乘积。最终无符号减法按 P_WIDTH 位补码回绕。
    wire signed [P_WIDTH-1:0] a0_value = A_SIGNED != 0
        ? {{(P_WIDTH-A_WIDTH){a0[A_WIDTH-1]}}, a0} : {{(P_WIDTH-A_WIDTH){1'b0}}, a0};
    wire signed [P_WIDTH-1:0] a1_value = A_SIGNED != 0
        ? {{(P_WIDTH-A_WIDTH){a1[A_WIDTH-1]}}, a1} : {{(P_WIDTH-A_WIDTH){1'b0}}, a1};
    wire signed [P_WIDTH-1:0] b0_value = B_SIGNED != 0
        ? {{(P_WIDTH-B_WIDTH){b0[B_WIDTH-1]}}, b0} : {{(P_WIDTH-B_WIDTH){1'b0}}, b0};
    wire signed [P_WIDTH-1:0] b1_value = B_SIGNED != 0
        ? {{(P_WIDTH-B_WIDTH){b1[B_WIDTH-1]}}, b1} : {{(P_WIDTH-B_WIDTH){1'b0}}, b1};
    wire signed [P_WIDTH-1:0] product0 = a0_value * b0_value;
    wire signed [P_WIDTH-1:0] product1 = a1_value * b1_value;
    wire [P_WIDTH-1:0] pair_result = STATIC_SUBTRACT != 0
        ? product0 - product1 : product0 + product1;
    wire unused_addsub = addsub;

    generate
        if (PIPE_STAGES == 0) begin : g_combinational
            // 0 级没有时钟、复位和使能作用；结果随输入组合变化。
            wire unused_clk = clk, unused_rst = rst, unused_ce = ce;
            assign p = pair_result;
        end else begin : g_pipeline
            localparam integer DEPTH = PIPE_STAGES > 0 ? PIPE_STAGES : 1;
            reg [P_WIDTH-1:0] result_pipe [0:DEPTH-1];
            integer stage;
            if (ASYNC_RESET != 0) begin : g_async
                always @(posedge clk or posedge rst) begin
                    if (rst) begin
                        for (stage = 0; stage < DEPTH; stage = stage + 1)
                            result_pipe[stage] <= 0;
                    end else if (ce) begin
                        result_pipe[0] <= pair_result;
                        for (stage = 1; stage < DEPTH; stage = stage + 1)
                            result_pipe[stage] <= result_pipe[stage-1];
                    end
                end
            end else begin : g_sync
                always @(posedge clk) begin
                    if (rst) begin
                        for (stage = 0; stage < DEPTH; stage = stage + 1)
                            result_pipe[stage] <= 0;
                    end else if (ce) begin
                        result_pipe[0] <= pair_result;
                        for (stage = 1; stage < DEPTH; stage = stage + 1)
                            result_pipe[stage] <= result_pipe[stage-1];
                    end
                end
            end
            assign p = result_pipe[DEPTH-1];
        end
    endgenerate

    // synthesis translate_off
    initial begin
        if ((A_SIGNED != 0 && A_SIGNED != 1) || (B_SIGNED != 0 && B_SIGNED != 1) ||
            A_WIDTH < 2 || A_WIDTH > (A_SIGNED != 0 ? 73 : 72) ||
            B_WIDTH < 2 || B_WIDTH > (B_SIGNED != 0 ? 66 : 65) ||
            PIPE_STAGES < 0 || PIPE_STAGES > 5 ||
            (ASYNC_RESET != 0 && ASYNC_RESET != 1) ||
            (STATIC_SUBTRACT != 0 && STATIC_SUBTRACT != 1))
            $fatal(1, "multiply_adder: invalid static-mode IP configuration");
    end
    // synthesis translate_on
endmodule

`default_nettype wire
