`timescale 1ns/1ps
`default_nettype none

// 可配置单层卷积的正确性基线：单乘法器，尺寸在每次命令握手时锁存。
// 本模块只计算 sum(input * weight) + bias，不猜测模型的缩放/舍入规则。
// 上层缓存适配器按坐标提供操作数；这里不直连 DDR，也不储存整张特征图。
// req/rsp 分别握手，允许任意停顿；最多只有一条已接收、未响应的请求。
// 所有端口均在 clk 域，rst_n 需与操作数适配器共同复位。
module conv2d_core #(
    parameter integer ACT_WIDTH = 8,
    parameter integer WEIGHT_WIDTH = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire cmd_valid,
    output wire cmd_ready,
    input  wire [15:0] cfg_in_h,
    input  wire [15:0] cfg_in_w,
    input  wire [15:0] cfg_in_ch,
    input  wire [15:0] cfg_out_ch,
    input  wire [1:0] cfg_kernel,   // 1 或 3
    input  wire [1:0] cfg_stride,   // 1 或 2
    input  wire [1:0] cfg_padding,  // 0 或 1，四边相同
    input  wire cfg_bias_enable,
    input  wire clear_status,
    output wire busy,
    output reg done,
    output reg error,
    output reg [1:0] error_code,
    output reg [16:0] out_h,
    output reg [16:0] out_w,

    output wire req_valid,
    input  wire req_ready,
    output wire req_bias,          // 1：取当前输出通道的 bias；0：取一对乘法操作数
    output wire [15:0] req_in_y,
    output wire [15:0] req_in_x,
    output wire [15:0] req_in_ch,
    output wire [15:0] req_out_ch,
    output wire [1:0] req_ky,
    output wire [1:0] req_kx,
    input  wire rsp_valid,
    output wire rsp_ready,
    input  wire signed [ACT_WIDTH-1:0] rsp_input,
    input  wire signed [WEIGHT_WIDTH-1:0] rsp_weight,
    input  wire signed [31:0] rsp_bias, // 必须已经换算到乘加结果所在的整数尺度

    output wire out_valid,
    input  wire out_ready,
    output wire signed [63:0] out_sum,
    output wire [16:0] out_y,
    output wire [16:0] out_x,
    output wire [15:0] out_ch,
    output wire out_last
);
    localparam [3:0] S_IDLE = 0, S_BIAS_REQ = 1, S_BIAS_WAIT = 2,
                     S_TAP = 3, S_MAC_REQ = 4, S_MAC_WAIT = 5,
                     S_STEP = 6, S_OUTPUT = 7;
    localparam integer PRODUCT_WIDTH = ACT_WIDTH + WEIGHT_WIDTH;
    reg [3:0] state;
    reg [15:0] in_h, in_w, in_ch, output_channels;
    reg [1:0] kernel, stride, padding;
    reg bias_enable;
    reg [16:0] output_y, output_x;
    reg [15:0] output_ch, input_ch;
    reg [1:0] ky, kx;
    reg signed [17:0] base_y, base_x;
    reg signed [63:0] accumulator;

    // 步长限定为 1/2，输出尺寸只需移位，不引入可变除法器。
    wire [16:0] padded_h = {1'b0, cfg_in_h} + ({15'd0, cfg_padding} << 1);
    wire [16:0] padded_w = {1'b0, cfg_in_w} + ({15'd0, cfg_padding} << 1);
    wire [16:0] calculated_h = ((padded_h - {15'd0, cfg_kernel}) >> (cfg_stride == 2)) + 17'd1;
    wire [16:0] calculated_w = ((padded_w - {15'd0, cfg_kernel}) >> (cfg_stride == 2)) + 17'd1;
    wire signed [17:0] sample_y = base_y + $signed({16'd0, ky});
    wire signed [17:0] sample_x = base_x + $signed({16'd0, kx});
    wire inside_image = sample_y >= 0 && sample_x >= 0 &&
                        sample_y < $signed({2'd0, in_h}) && sample_x < $signed({2'd0, in_w});
    wire signed [PRODUCT_WIDTH-1:0] product = $signed(rsp_input) * $signed(rsp_weight);
    wire signed [63:0] extended_product = {{(64-PRODUCT_WIDTH){product[PRODUCT_WIDTH-1]}}, product};
    wire last_output = output_y == out_h - 17'd1 && output_x == out_w - 17'd1 &&
                       output_ch == output_channels - 16'd1;

    assign cmd_ready = rst_n && state == S_IDLE;
    assign busy = state != S_IDLE;
    assign req_valid = rst_n && (state == S_BIAS_REQ || state == S_MAC_REQ);
    assign req_bias = state == S_BIAS_REQ;
    // bias 请求只使用 req_out_ch；其它坐标归零，避免暴露 padding 的负坐标。
    assign req_in_y = req_bias ? 16'd0 : sample_y[15:0];
    assign req_in_x = req_bias ? 16'd0 : sample_x[15:0];
    assign req_in_ch = req_bias ? 16'd0 : input_ch;
    assign req_out_ch = output_ch;
    assign req_ky = req_bias ? 2'd0 : ky;
    assign req_kx = req_bias ? 2'd0 : kx;
    assign rsp_ready = rst_n && (state == S_BIAS_WAIT || state == S_MAC_WAIT);
    assign out_valid = rst_n && state == S_OUTPUT;
    assign out_sum = accumulator;
    assign out_y = output_y;
    assign out_x = output_x;
    assign out_ch = output_ch;
    assign out_last = out_valid && last_output;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 0; error <= 0; error_code <= 0;
            in_h <= 0; in_w <= 0; in_ch <= 0; output_channels <= 0;
            kernel <= 1; stride <= 1; padding <= 0; bias_enable <= 0;
            out_h <= 0; out_w <= 0; output_y <= 0; output_x <= 0;
            output_ch <= 0; input_ch <= 0; ky <= 0; kx <= 0;
            base_y <= 0; base_x <= 0; accumulator <= 0;
        end else begin
            if (state == S_IDLE && clear_status) begin
                done <= 0; error <= 0; error_code <= 0;
            end
            case (state)
                S_IDLE: if (cmd_valid && cmd_ready) begin
                    done <= 0; error <= 0; error_code <= 0;
                    if (cfg_in_h == 0 || cfg_in_w == 0 || cfg_in_ch == 0 || cfg_out_ch == 0) begin
                        error <= 1; error_code <= 1;
                    end else if ((cfg_kernel != 1 && cfg_kernel != 3) ||
                                 (cfg_stride != 1 && cfg_stride != 2) || cfg_padding > 1) begin
                        error <= 1; error_code <= 2;
                    end else if (padded_h < {15'd0, cfg_kernel} || padded_w < {15'd0, cfg_kernel}) begin
                        error <= 1; error_code <= 3;
                    end else begin
                        in_h <= cfg_in_h; in_w <= cfg_in_w; in_ch <= cfg_in_ch;
                        output_channels <= cfg_out_ch; kernel <= cfg_kernel;
                        stride <= cfg_stride; padding <= cfg_padding; bias_enable <= cfg_bias_enable;
                        out_h <= calculated_h[16:0]; out_w <= calculated_w[16:0];
                        output_y <= 0; output_x <= 0; output_ch <= 0;
                        input_ch <= 0; ky <= 0; kx <= 0; accumulator <= 0;
                        base_y <= -$signed({16'd0, cfg_padding});
                        base_x <= -$signed({16'd0, cfg_padding});
                        state <= cfg_bias_enable ? S_BIAS_REQ : S_TAP;
                    end
                end
                S_BIAS_REQ: if (req_valid && req_ready) state <= S_BIAS_WAIT;
                S_BIAS_WAIT: if (rsp_valid && rsp_ready) begin
                    accumulator <= {{32{rsp_bias[31]}}, rsp_bias};
                    state <= S_TAP;
                end
                S_TAP: begin
                    // 越界 tap 的所有通道贡献都为零，直接跳过，也不读取该 tap 的权重。
                    if (inside_image) state <= S_MAC_REQ;
                    else state <= S_STEP;
                end
                S_MAC_REQ: if (req_valid && req_ready) state <= S_MAC_WAIT;
                S_MAC_WAIT: if (rsp_valid && rsp_ready) begin
                    accumulator <= accumulator + extended_product;
                    if (input_ch == in_ch - 16'd1) begin
                        input_ch <= 0; state <= S_STEP;
                    end else begin
                        input_ch <= input_ch + 16'd1; state <= S_MAC_REQ;
                    end
                end
                S_STEP: begin
                    if (kx == kernel - 2'd1) begin
                        kx <= 0;
                        if (ky == kernel - 2'd1) begin ky <= 0; state <= S_OUTPUT; end
                        else begin ky <= ky + 2'd1; state <= S_TAP; end
                    end else begin kx <= kx + 2'd1; state <= S_TAP; end
                end
                S_OUTPUT: if (out_valid && out_ready) begin
                    if (last_output) begin state <= S_IDLE; done <= 1; end
                    else begin
                        // 输出采用 HWC 顺序：同一像素的所有输出通道连续产生。
                        if (output_ch != output_channels - 16'd1) output_ch <= output_ch + 16'd1;
                        else begin
                            output_ch <= 0;
                            if (output_x != out_w - 17'd1) begin
                                output_x <= output_x + 17'd1;
                                base_x <= base_x + $signed({16'd0, stride});
                            end else begin
                                output_x <= 0; output_y <= output_y + 17'd1;
                                base_x <= -$signed({16'd0, padding});
                                base_y <= base_y + $signed({16'd0, stride});
                            end
                        end
                        input_ch <= 0; ky <= 0; kx <= 0; accumulator <= 0;
                        state <= bias_enable ? S_BIAS_REQ : S_TAP;
                    end
                end
                default: begin state <= S_IDLE; error <= 1; error_code <= 3; end
            endcase
        end
    end

    // synthesis translate_off
    initial if (ACT_WIDTH < 2 || ACT_WIDTH > 16 || WEIGHT_WIDTH < 2 || WEIGHT_WIDTH > 16)
        $fatal(1, "conv2d_core: operand width must be 2..16");
    // synthesis translate_on
endmodule
`default_nettype wire
