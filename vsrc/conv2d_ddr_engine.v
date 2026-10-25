`timescale 1ns/1ps
`default_nettype none
// W8A8 单层 DDR 原始卷积：4 个输出通道 x 2 项归约，4 个相邻输出像素为一小块。
// HWC 输入的物理通道补齐到 16，输出通道补齐到 4，权重为 O-KY-KX-I。
// 所有内存操作均为 16/32 字节对齐块；部分和跨输入通道块保存在片上。
module conv2d_ddr_engine (
    input wire clk, rst_n,
    input wire cmd_valid, output wire cmd_ready,
    input wire [31:0] cfg_input_addr, cfg_weight_addr, cfg_bias_addr, cfg_output_addr,
    input wire [15:0] cfg_in_h, cfg_in_w, cfg_in_ch, cfg_out_ch,
    input wire [1:0] cfg_kernel, cfg_stride, cfg_padding,
    input wire cfg_bias_enable, clear_status,
    output wire busy, output reg done, error,
    output reg [3:0] error_code,
    output reg [31:0] out_h, out_w, total_cycles, mac_issues,
    output wire dma_cmd_valid, input wire dma_cmd_ready,
    output wire dma_cmd_write,
    output wire [31:0] dma_cmd_addr, dma_cmd_len,
    input wire dma_done, dma_error, dma_fault, dma_initialized,
    input wire [3:0] dma_error_code,
    output wire dma_wr_valid, input wire dma_wr_ready,
    output wire [127:0] dma_wr_data,
    input wire dma_rd_valid, output wire dma_rd_ready,
    input wire [127:0] dma_rd_data
);
    localparam [3:0] IDLE=0, B_REQ=1, B_WAIT=2, INIT=3,
        W_REQ=4, W_WAIT=5, P_REQ=6, P_WAIT=7, T_START=8, T_WAIT=9, O_REQ=10, O_WAIT=11;
    reg [3:0] state;
    reg [31:0] input_addr, weight_addr, bias_addr, output_addr;
    reg [15:0] height, width, input_channels, output_channels;
    reg [31:0] ci_pitch, co_pitch, ci_base, co_base, y, x_tile;
    reg [1:0] stride, padding, weight_lane;
    reg [3:0] taps, tap;
    reg bias_enable;
    reg [2:0] pixel, tile_width;
    reg [127:0] biases;
    reg [255:0] partials [0:3];
    wire [31:0] cfg_ci_pitch=({16'd0,cfg_in_ch}+32'd15)&32'hfffffff0;
    wire [31:0] cfg_co_pitch=({16'd0,cfg_out_ch}+32'd3)&32'hfffffffc;
    wire [31:0] padded_h={16'd0,cfg_in_h}+({30'd0,cfg_padding}<<1);
    wire [31:0] padded_w={16'd0,cfg_in_w}+({30'd0,cfg_padding}<<1);
    wire [31:0] calc_h=((padded_h-{30'd0,cfg_kernel})>>(cfg_stride==2))+1;
    wire [31:0] calc_w=((padded_w-{30'd0,cfg_kernel})>>(cfg_stride==2))+1;
    wire [63:0] input_size={48'd0,cfg_in_h}*{48'd0,cfg_in_w}*{32'd0,cfg_ci_pitch};
    wire [63:0] weight_size={32'd0,cfg_co_pitch}*{62'd0,cfg_kernel}*{62'd0,cfg_kernel}*{32'd0,cfg_ci_pitch};
    wire [63:0] bias_size={32'd0,cfg_co_pitch}*64'd4;
    wire [63:0] output_size={32'd0,calc_h}*{32'd0,calc_w}*{32'd0,cfg_co_pitch}*64'd8;
    wire [63:0] ie={32'd0,cfg_input_addr}+input_size, we={32'd0,cfg_weight_addr}+weight_size;
    wire [63:0] be={32'd0,cfg_bias_addr}+bias_size, oe={32'd0,cfg_output_addr}+output_size;
    wire address_bad=ie>64'h20000000 || we>64'h20000000 || oe>64'h20000000 ||
        (cfg_bias_enable && be>64'h20000000);
    // 只读区域允许相互重叠；输出禁止覆盖任意正在读取的区域。
    wire overlap_bad=({32'd0,cfg_output_addr}<ie && {32'd0,cfg_input_addr}<oe) ||
        ({32'd0,cfg_output_addr}<we && {32'd0,cfg_weight_addr}<oe) ||
        (cfg_bias_enable && {32'd0,cfg_output_addr}<be && {32'd0,cfg_bias_addr}<oe);
    wire [3:0] ty=taps==1 ? 4'd0 : tap/4'd3, tx=taps==1 ? 4'd0 : tap%4'd3;
    wire signed [31:0] iy=$signed(stride==2 ? y<<1 : y)+$signed({28'd0,ty})-$signed({30'd0,padding});
    wire [31:0] ox=x_tile+{29'd0,pixel};
    wire signed [31:0] ix=$signed(stride==2 ? ox<<1 : ox)+$signed({28'd0,tx})-$signed({30'd0,padding});
    wire inside_image=iy>=0 && ix>=0 && iy<$signed({16'd0,height}) && ix<$signed({16'd0,width});
    wire lane_valid=co_base+{30'd0,weight_lane}<{16'd0,output_channels};
    wire [31:0] weight_pointer=weight_addr+((co_base+{30'd0,weight_lane})*{28'd0,taps}+{28'd0,tap})*ci_pitch+ci_base;
    wire [31:0] input_pointer=input_addr+($unsigned(iy)*{16'd0,width}+$unsigned(ix))*ci_pitch+ci_base;
    wire [31:0] next_tile_remaining=out_w-x_tile-32'd4;
    wire [31:0] output_pointer=output_addr+((y*out_w+ox)*co_pitch+co_base)*8;
    wire creq_ready, crsp_valid, crsp_error;
    wire [3:0] crsp_code;
    wire [255:0] crsp_data;
    wire [127:0] unused_read_high=crsp_data[255:128];
    wire creq_valid=(state==B_REQ || (state==W_REQ && lane_valid) ||
        (state==P_REQ && inside_image) || state==O_REQ);
    wire [31:0] creq_addr=state==B_REQ ? bias_addr+co_base*4 :
        state==W_REQ ? weight_pointer : state==P_REQ ? input_pointer : output_pointer;
    wire load_ready, tile_start_ready, tile_out_valid, tile_error, tile_busy, issue;
    wire [255:0] tile_result;
    wire tile_load_valid=(state==W_REQ && !lane_valid) || (state==P_REQ && !inside_image) ||
        ((state==W_WAIT || state==P_WAIT) && crsp_valid && !crsp_error);
    wire crsp_ready=(state==B_WAIT || state==O_WAIT) ||
        ((state==W_WAIT || state==P_WAIT) && (crsp_error || load_ready));
    reg [127:0] patch_data;
    integer mask_byte;
    always @* begin
        patch_data=crsp_data[127:0];
        for(mask_byte=0;mask_byte<16;mask_byte=mask_byte+1)
            if(ci_base+mask_byte>={16'd0,input_channels}) patch_data[mask_byte*8 +: 8]=0;
    end
    wire [127:0] cache_data=(state==W_REQ || state==P_REQ) ? 128'd0 :
        state==P_WAIT ? patch_data : crsp_data[127:0];
    assign cmd_ready=rst_n && state==IDLE && !dma_fault && dma_initialized;
    assign busy=state!=IDLE;
    ddr_chunk_client u_client (
        .clk(clk), .rst_n(rst_n), .req_valid(creq_valid), .req_ready(creq_ready),
        .req_write(state==O_REQ), .req_two(state==O_REQ), .req_addr(creq_addr),
        .req_data(partials[pixel[1:0]]), .rsp_valid(crsp_valid), .rsp_ready(crsp_ready),
        .rsp_data(crsp_data), .rsp_error(crsp_error), .rsp_code(crsp_code),
        .dma_cmd_valid(dma_cmd_valid),
        .dma_cmd_ready(dma_cmd_ready),
        .dma_cmd_write(dma_cmd_write),
        .dma_cmd_addr(dma_cmd_addr),
        .dma_cmd_len(dma_cmd_len),
        .dma_done(dma_done),
        .dma_error(dma_error),
        .dma_fault(dma_fault), .dma_initialized(dma_initialized),
        .dma_error_code(dma_error_code),
        .dma_wr_valid(dma_wr_valid),
        .dma_wr_ready(dma_wr_ready),
        .dma_wr_data(dma_wr_data),
        .dma_rd_valid(dma_rd_valid),
        .dma_rd_ready(dma_rd_ready),
        .dma_rd_data(dma_rd_data)
    );
    conv_mac_tile u_tile (
        .clk(clk), .rst_n(rst_n), .load_valid(tile_load_valid), .load_ready(load_ready),
        .load_weight(state==W_REQ || state==W_WAIT), .load_lane(weight_lane), .load_tap(tap), .load_data(cache_data),
        .start_valid(state==T_START), .start_ready(tile_start_ready), .tap_count(taps),
        .initial_sums(partials[pixel[1:0]]), .compute_enable(1'b1), .busy(tile_busy), .error(tile_error),
        .out_valid(tile_out_valid), .out_ready(state==T_WAIT), .out_sums(tile_result), .issue_valid(issue)
    );
    wire unused_tile_busy=tile_busy;
    task next_weight;
        begin
            if(tap==taps-1'b1) begin
                tap<=0;
                if(weight_lane==3) begin weight_lane<=0; pixel<=0; state<=P_REQ; end
                else begin weight_lane<=weight_lane+1'b1; state<=W_REQ; end
            end else begin tap<=tap+1'b1; state<=W_REQ; end
        end
    endtask
    task next_patch;
        begin
            if(tap==taps-1'b1) begin tap<=0; state<=T_START; end
            else begin tap<=tap+1'b1; state<=P_REQ; end
        end
    endtask
    integer i,j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; done<=0; error<=0; error_code<=0;
            input_addr<=0; weight_addr<=0; bias_addr<=0; output_addr<=0;
            height<=0; width<=0; input_channels<=0; output_channels<=0;
            ci_pitch<=0; co_pitch<=0; ci_base<=0; co_base<=0; y<=0; x_tile<=0;
            stride<=1; padding<=0; weight_lane<=0; taps<=1; tap<=0; bias_enable<=0;
            pixel<=0; tile_width<=0; biases<=0; out_h<=0; out_w<=0; total_cycles<=0; mac_issues<=0;
            for(i=0;i<4;i=i+1) partials[i]<=0;
        end else begin
            if(busy) total_cycles<=total_cycles+1'b1;
            if(issue) mac_issues<=mac_issues+1'b1;
            if(state==IDLE && clear_status) begin done<=0; error<=0; error_code<=0; end
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    done<=0; error<=0; error_code<=0; total_cycles<=0; mac_issues<=0; out_h<=0; out_w<=0;
                    if(cfg_in_h==0 || cfg_in_w==0 || cfg_in_ch==0 || cfg_out_ch==0) begin error<=1; error_code<=1; end
                    else if((cfg_kernel!=1 && cfg_kernel!=3) || (cfg_stride!=1 && cfg_stride!=2) || cfg_padding>1 ||
                        padded_h<{30'd0,cfg_kernel} || padded_w<{30'd0,cfg_kernel}) begin error<=1; error_code<=2; end
                    else if(cfg_input_addr[3:0]!=0 || cfg_weight_addr[3:0]!=0 || cfg_output_addr[3:0]!=0 ||
                        (cfg_bias_enable && cfg_bias_addr[3:0]!=0)) begin error<=1; error_code<=4; end
                    else if(address_bad) begin error<=1; error_code<=3; end
                    else if(overlap_bad) begin error<=1; error_code<=5; end
                    else begin
                        input_addr<=cfg_input_addr; weight_addr<=cfg_weight_addr; bias_addr<=cfg_bias_addr; output_addr<=cfg_output_addr;
                        height<=cfg_in_h; width<=cfg_in_w; input_channels<=cfg_in_ch; output_channels<=cfg_out_ch;
                        ci_pitch<=cfg_ci_pitch; co_pitch<=cfg_co_pitch; stride<=cfg_stride; padding<=cfg_padding;
                        bias_enable<=cfg_bias_enable; taps<=cfg_kernel==3 ? 4'd9 : 4'd1;
                        out_h<=calc_h; out_w<=calc_w; ci_base<=0; co_base<=0; y<=0; x_tile<=0; pixel<=0; tap<=0; weight_lane<=0;
                        tile_width<=calc_w>=4 ? 3'd4 : calc_w[2:0]; biases<=0;
                        state<=cfg_bias_enable ? B_REQ : INIT;
                    end
                end
                B_REQ: if(creq_valid && creq_ready) state<=B_WAIT;
                B_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin biases<=crsp_data[127:0]; state<=INIT; end
                INIT: begin
                    for(i=0;i<4;i=i+1) for(j=0;j<4;j=j+1)
                        partials[i][j*64 +: 64]<=bias_enable && co_base+j<{16'd0,output_channels}
                            ? {{32{biases[j*32+31]}},biases[j*32 +: 32]} : 64'd0;
                    ci_base<=0; tap<=0; weight_lane<=0; pixel<=0; state<=W_REQ;
                end
                W_REQ: if(!lane_valid) begin if(load_ready) next_weight; end
                       else if(creq_valid && creq_ready) state<=W_WAIT;
                W_WAIT: if(crsp_valid && crsp_ready && !crsp_error) next_weight;
                P_REQ: if(!inside_image) begin if(load_ready) next_patch; end
                       else if(creq_valid && creq_ready) state<=P_WAIT;
                P_WAIT: if(crsp_valid && crsp_ready && !crsp_error) next_patch;
                T_START: if(tile_start_ready) state<=T_WAIT;
                T_WAIT: if(tile_error) begin error<=1; error_code<=6; state<=IDLE; end
                    else if(tile_out_valid) begin
                        partials[pixel[1:0]]<=tile_result;
                        if(pixel+3'd1<tile_width) begin pixel<=pixel+1'b1; tap<=0; state<=P_REQ; end
                        else if(ci_base+32'd16<{16'd0,input_channels}) begin
                            ci_base<=ci_base+32'd16; pixel<=0; tap<=0; weight_lane<=0; state<=W_REQ;
                        end else begin pixel<=0; state<=O_REQ; end
                    end
                O_REQ: if(creq_valid && creq_ready) state<=O_WAIT;
                O_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin
                    if(pixel+3'd1<tile_width) begin pixel<=pixel+1'b1; state<=O_REQ; end
                    else if(x_tile+32'd4<out_w) begin
                        x_tile<=x_tile+32'd4;
                        tile_width<=next_tile_remaining>=4 ? 3'd4 : next_tile_remaining[2:0];
                        state<=INIT;
                    end else if(y+1<out_h) begin
                        x_tile<=0; y<=y+1'b1; tile_width<=out_w>=4 ? 3'd4 : out_w[2:0]; state<=INIT;
                    end else if(co_base+32'd4<{16'd0,output_channels}) begin
                        co_base<=co_base+32'd4; y<=0; x_tile<=0;
                        tile_width<=out_w>=4 ? 3'd4 : out_w[2:0]; biases<=0; state<=bias_enable ? B_REQ : INIT;
                    end else begin state<=IDLE; done<=1; end
                end
                default: begin state<=IDLE; error<=1; error_code<=6; end
            endcase
            if(crsp_valid && crsp_ready && crsp_error) begin
                state<=IDLE; done<=0; error<=1; error_code<=4'h8 | crsp_code;
            end
        end
    end
endmodule
`default_nettype wire
