`timescale 1ns/1ps
`default_nettype none
// 一个输出像素、最多四个输出通道的可复用 W8A16 卷积块。
// 地址生成、padding、尾通道补零由供数端负责；每块含 16 个输入通道。
// 按组0全部输入块、组1全部输入块的顺序装载，组间尺度可以不同。
// 这里的“组”只用于量化尺度，不是减少通道连接的 group convolution。
// 本阶段独立于 DDR/MMIO，后续控制器复用同一接口；不是完整检测网络。
module conv2d_w8a16_core (
    input wire clk, rst_n,
    input wire start_valid, output wire start_ready,
    input wire [3:0] cfg_taps, cfg_lane_mask,
    input wire [15:0] cfg_blocks0, cfg_blocks1,
    input wire [127:0] cfg_mult_m0, cfg_mult_m1, cfg_bias_q13, cfg_mult_y,
    input wire [31:0] cfg_shift_m0, cfg_shift_m1, cfg_shift_y,
    input wire cfg_relu,
    input wire load_valid, output wire load_ready,
    input wire load_weight,
    input wire [1:0] load_lane,
    input wire [3:0] load_tap,
    input wire [255:0] load_data, // 输入：16xINT16；权重：低128位的16xINT8
    input wire block_valid, output wire block_ready,
    input wire compute_enable,
    output wire busy, issue_valid,
    output wire out_valid, input wire out_ready,
    output reg [63:0] out_data,
    output reg out_error,
    output reg [3:0] out_clamped
);
    localparam [2:0] IDLE=0, LOAD=1, COMPUTE=2, QUANT_START=3, QUANT_WAIT=4, RESULT=5;
    reg [2:0] state;
    reg [3:0] taps, lane_mask;
    reg [15:0] blocks0, blocks1, block_index;
    reg current_group, relu_reg;
    reg [127:0] mult_m0, mult_m1, bias_q13, mult_y;
    reg [31:0] shift_m0, shift_m1, shift_y;
    reg [255:0] partial0, partial1;
    reg [1:0] quant_lane;
    reg [8:0] loaded_input, loaded_weight[0:3];
    wire [8:0] required=taps==1 ? 9'b1 : 9'h1ff;
    wire complete_cache=(loaded_input & required)==required &&
        (loaded_weight[0] & required)==required && (loaded_weight[1] & required)==required &&
        (loaded_weight[2] & required)==required && (loaded_weight[3] & required)==required;
    wire tile_load_ready, tile_start_ready, tile_valid, tile_error, tile_busy;
    wire [255:0] tile_sums;
    wire tile_start=block_valid && block_ready;
    assign start_ready=rst_n && state==IDLE;
    assign load_ready=rst_n && state==LOAD && !block_valid && tile_load_ready;
    assign block_ready=rst_n && state==LOAD && complete_cache && tile_start_ready;
    assign busy=state!=IDLE;
    assign out_valid=rst_n && state==RESULT;
    conv_mac_tile #(.ACT_WIDTH(16)) u_tile (
        .clk(clk),.rst_n(rst_n),.load_valid(load_valid && state==LOAD && !block_valid),
        .load_ready(tile_load_ready),.load_weight(load_weight),.load_lane(load_lane),
        .load_tap(load_tap),.load_data(load_data),
        .start_valid(tile_start),.start_ready(tile_start_ready),.tap_count(taps),
        .initial_sums(current_group ? partial1 : partial0),.compute_enable(compute_enable),
        .busy(tile_busy),.error(tile_error),.out_valid(tile_valid),.out_ready(state==COMPUTE),
        .out_sums(tile_sums),.issue_valid(issue_valid)
    );
    wire unused_tile_busy=tile_busy;
    wire quant_ready, quant_valid, quant_error, quant_clamped;
    wire [15:0] quant_data;
    requant_q13 u_quant (
        .clk(clk),.rst_n(rst_n),.in_valid(state==QUANT_START),.in_ready(quant_ready),
        .in_sum0(partial0[quant_lane*64 +: 64]),.in_sum1(partial1[quant_lane*64 +: 64]),
        .group1_enable(blocks1!=0),.mult_m0(mult_m0[quant_lane*32 +: 32]),.shift_m0(shift_m0),
        .mult_m1(mult_m1[quant_lane*32 +: 32]),.shift_m1(shift_m1),
        .bias_q13(bias_q13[quant_lane*32 +: 32]),.mult_y(mult_y[quant_lane*32 +: 32]),
        .shift_y(shift_y),.relu(relu_reg),.out_valid(quant_valid),.out_ready(state==QUANT_WAIT),
        .out_data(quant_data),.out_error(quant_error),.out_clamped(quant_clamped)
    );
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; taps<=1; lane_mask<=0; blocks0<=0; blocks1<=0; block_index<=0;
            current_group<=0; relu_reg<=0; mult_m0<=0; mult_m1<=0; bias_q13<=0; mult_y<=0;
            shift_m0<=0; shift_m1<=0; shift_y<=0; partial0<=0; partial1<=0; quant_lane<=0;
            loaded_input<=0; out_data<=0; out_error<=0; out_clamped<=0;
            for(i=0;i<4;i=i+1) loaded_weight[i]<=0;
        end else begin
            if(load_valid && load_ready) begin
                if(load_weight) loaded_weight[load_lane][load_tap]<=1;
                else loaded_input[load_tap]<=1;
            end
            case(state)
                IDLE: if(start_valid && start_ready) begin
                    taps<=cfg_taps; lane_mask<=cfg_lane_mask;
                    blocks0<=cfg_blocks0; blocks1<=cfg_blocks1; relu_reg<=cfg_relu;
                    mult_m0<=cfg_mult_m0; mult_m1<=cfg_mult_m1; bias_q13<=cfg_bias_q13; mult_y<=cfg_mult_y;
                    shift_m0<=cfg_shift_m0; shift_m1<=cfg_shift_m1; shift_y<=cfg_shift_y;
                    partial0<=0; partial1<=0; current_group<=0; block_index<=0; quant_lane<=0;
                    loaded_input<=0; out_data<=0; out_error<=0; out_clamped<=0;
                    for(i=0;i<4;i=i+1) loaded_weight[i]<=0;
                    if((cfg_taps!=1 && cfg_taps!=9) || cfg_blocks0==0 || cfg_lane_mask==0) begin
                        out_error<=1; state<=RESULT;
                    end else state<=LOAD;
                end
                LOAD: if(tile_start) begin
                    // 每个输入块都要求重新装满，避免无意使用上一块的陈旧缓存。
                    loaded_input<=0;
                    for(i=0;i<4;i=i+1) loaded_weight[i]<=0;
                    state<=COMPUTE;
                end
                COMPUTE: if(tile_error) begin out_error<=1; state<=RESULT; end
                    else if(tile_valid) begin
                        if(current_group) partial1<=tile_sums; else partial0<=tile_sums;
                        if(block_index+16'd1<(current_group ? blocks1 : blocks0)) begin
                            block_index<=block_index+16'd1; state<=LOAD;
                        end else if(!current_group && blocks1!=0) begin
                            current_group<=1; block_index<=0; state<=LOAD;
                        end else begin quant_lane<=0; state<=QUANT_START; end
                    end
                QUANT_START: if(quant_ready) state<=QUANT_WAIT;
                QUANT_WAIT: if(quant_valid) begin
                    out_data[quant_lane*16 +: 16]<=lane_mask[quant_lane] ? quant_data : 16'd0;
                    out_clamped[quant_lane]<=lane_mask[quant_lane] && quant_clamped;
                    out_error<=out_error || (lane_mask[quant_lane] && quant_error);
                    if(quant_lane==3) state<=RESULT;
                    else begin quant_lane<=quant_lane+1'b1; state<=QUANT_START; end
                end
                RESULT: if(out_ready) state<=IDLE;
                default: begin out_error<=1; state<=RESULT; end
            endcase
        end
    end
endmodule
`default_nettype wire
