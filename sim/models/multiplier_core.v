// 根据《简单乘法器.pdf》(UG041003) 编写的 Simple Multiplier 行为模型。
// 固定为有符号 33×33 位输入、66 位输出、高有效同步复位，关闭
// Advanced Mode / Optimal Timing。PIPE_STAGES=1 对应 XYREG，更多级数
// 继续延迟乘积；ce=0 时包括输入寄存器在内的所有寄存器保持。
// 仅模拟接口和周期延迟，不代表紫光 APM 的内部结构、资源占用或物理时序。
module multiplier_core #(
    parameter integer PIPE_STAGES = 3
)(
    input clk,
    input rst,
    input ce,
    input signed [32:0] a,
    input signed [32:0] b,
    output signed [65:0] p
);
    reg signed [32:0] a_reg;
    reg signed [32:0] b_reg;
    wire signed [65:0] product = a_reg * b_reg;

    always @(posedge clk) begin
        if (rst) begin
            a_reg <= 0;
            b_reg <= 0;
        end else if (ce) begin
            a_reg <= a;
            b_reg <= b;
        end
    end

    generate
        if (PIPE_STAGES == 1) begin : g_input_only
            assign p = product;
        end else begin : g_pipeline
            reg signed [65:0] pipeline [0:PIPE_STAGES-2];
            integer i;
            always @(posedge clk) begin
                if (rst) begin
                    for (i = 0; i < PIPE_STAGES-1; i = i+1)
                        pipeline[i] <= 0;
                end else if (ce) begin
                    pipeline[0] <= product;
                    for (i = 1; i < PIPE_STAGES-1; i = i+1)
                        pipeline[i] <= pipeline[i-1];
                end
            end
            assign p = pipeline[PIPE_STAGES-2];
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (PIPE_STAGES < 1 || PIPE_STAGES > 5)
            $fatal(1, "Simple Multiplier PIPE_STAGES must be in [1,5]");
    end
`endif
endmodule
