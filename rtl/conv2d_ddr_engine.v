`timescale 1ns/1ps
`default_nettype none
// W8A8/W8A16 DDR 卷积：4 个输出通道 x 2 项归约，4 个相邻输出像素为一小块。
// W8A8原始INT64按4通道对齐；量化INT8/INT16按16通道对齐，可直接连接下一层。
// 亦处理INT16 ADD、Concat、5x5最大池化和2倍最近邻上采样。
module conv2d_ddr_engine #(
    parameter integer ACT_WIDTH=8 // 综合配置：8保留原ABI，16使用两级Q13量化
)(
    input wire clk, rst_n,
    input wire cmd_valid, output wire cmd_ready,
    input wire [31:0] cfg_opcode, // 1=卷积，2=ADD，3=Concat，4=MaxPool5，5=Upsample2x
    input wire [31:0] cfg_input_addr, cfg_weight_addr, cfg_bias_addr, cfg_output_addr,
    input wire [31:0] cfg_quant_addr, cfg_post,
    input wire [31:0] cfg_group_split, // 卷积：尺度组边界；Concat：B输入通道数
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
    // The request toggle is synchronized by ddr_cpu_window; capture the held
    // bundle here before performing any arithmetic in the DDR clock domain.
    reg [31:0] held_opcode, held_input_addr, held_weight_addr, held_bias_addr, held_output_addr, held_quant_addr, held_post, held_group_split;
    reg [15:0] held_in_h, held_in_w, held_in_ch, held_out_ch;
    reg [1:0] held_kernel, held_stride, held_padding;
    reg held_bias_enable;

    localparam [5:0] IDLE=0, B_REQ=1, B_WAIT=2, INIT=3,
        W_REQ=4, W_WAIT=5, P_REQ=6, P_WAIT=7, T_START=8, T_WAIT=9, O_REQ=10, O_WAIT=11,
        QPAR_REQ=12, QPAR_WAIT=13, Q_START=14, Q_WAIT=15, MERGE_REQ=16, MERGE_WAIT=17,
        PAD_REQ=18, PAD_WAIT=19,
        ADD_QREQ=20,ADD_QWAIT=21,ADD_AREQ=22,ADD_AWAIT=23,ADD_BREQ=24,ADD_BWAIT=25,
        ADD_START=26,ADD_WAIT=27,ADD_OREQ=28,ADD_OWAIT=29,
        CAT_PREP=30,CAT_REQ=31,CAT_WAIT=32,CAT_COPY=33,CAT_OREQ=34,CAT_OWAIT=35,
        POOL_INIT=36,POOL_PREP=37,POOL_REQ=38,POOL_WAIT=39,POOL_OREQ=40,POOL_OWAIT=41,
        UP_PREP=42,UP_REQ=43,UP_WAIT=44,UP_OREQ=45,UP_OWAIT=46,
        CFG_PITCH=47,CFG_DIMS=48,CFG_START=49,CFG_WAIT=50,CFG_END=51,CFG_CHECK=52,CFG_VALIDATE=53;
    reg [5:0] state;
    reg [31:0] input_addr, weight_addr, bias_addr, output_addr, quant_addr;
    reg [15:0] height, width, input_channels, output_channels;
    reg [31:0] ci_pitch, co_pitch, ci_base, co_base, y, x_tile;
    reg [31:0] output_pitch;
    reg output_int8, relu_enable;
    reg [31:0] group_split;
    wire quantized=ACT_WIDTH==16 || output_int8;
    wire cfg_quantized=ACT_WIDTH==16 || held_post[0];
    wire current_group=ACT_WIDTH==16 && group_split!=0 && ci_base>=group_split;
    reg [1:0] quant_lane;
    reg [31:0] quant_multiplier[0:3], quant_shift[0:3];
    reg [31:0] quant_multiplier1[0:3],quant_shift1[0:3],quant_multiplier_y[0:3],quant_shift_y[0:3];
    reg [4*ACT_WIDTH-1:0] quant_pixels[0:3];
    reg [127:0] merge_word;
    reg [1:0] stride, padding, weight_lane;
    reg [3:0] taps, tap;
    reg bias_enable;
    reg [2:0] pixel, tile_width;
    reg [127:0] biases;
    reg [255:0] partials [0:3];
    reg [255:0] partials1 [0:3];
    reg [31:0] add_offset,add_bytes,add_channel;
    reg [31:0] add_mult_a,add_shift_a,add_mult_b,add_shift_b;
    reg [127:0] add_word_a,add_word_b,add_word_out;
    reg [2:0] add_lane;
    // Concat只有一个源字缓存和一个输出组装字；输入尾部填充不能进入逻辑通道。
    reg [31:0] cat_x,cat_y,cat_channel,cat_read_addr,cat_cache_addr;
    reg [2:0] cat_lane;
    reg cat_cache_valid;
    reg [127:0] cat_cache,cat_word;
    // 每次处理一个DDR字的8个通道；只保存窗口最大值，不缓存整张特征图。
    reg [31:0] pool_x,pool_y,pool_channel,pool_pixel_addr,pool_row_bytes;
    reg [31:0] pool_tap_row_addr,pool_tap_addr;
    reg [2:0] pool_kx,pool_ky;
    reg [127:0] pool_max;
    // 源字读一次，保留到对应2x2区域的四笔写入全部完成。
    reg [31:0] up_x,up_y,up_channel,up_row_bytes;
    reg [1:0] up_copy;
    reg [127:0] up_word;
    reg [31:0] cfg_ci_pitch,cfg_co_pitch,cfg_output_pitch,cfg_cat_b_pitch;
    reg [31:0] padded_h,padded_w,calc_h,calc_w;
    wire [63:0] input_size,weight_size,output_size,add_size,cat_b_size,cat_o_size;
    wire sizes_done;
    reg [63:0] ie,we,be,oe,quant_end,add_ae,add_be,add_oe,add_qe,cat_be,cat_oe;
    ai_config_sizes #(.ACT_WIDTH(ACT_WIDTH)) u_config_sizes(
        .clk(clk),.rst_n(rst_n),.start(state==CFG_START),
        .in_h(held_in_h),.in_w(held_in_w),.ci_pitch(cfg_ci_pitch),.co_pitch(cfg_co_pitch),
        .out_h(calc_h),.out_w(calc_w),.out_pitch(cfg_output_pitch),.cat_b_pitch(cfg_cat_b_pitch),
        .kernel(held_kernel),.quantized(cfg_quantized),.done(sizes_done),
        .input_size(input_size),.weight_size(weight_size),.output_size(output_size),
        .add_size(add_size),.cat_b_size(cat_b_size),.cat_o_size(cat_o_size));
    wire add_address_bad_raw=add_ae>64'h20000000 || add_be>64'h20000000 || add_oe>64'h20000000 || add_qe>64'h20000000;
    wire add_overlap_bad_raw=({32'd0,held_output_addr}<add_ae && {32'd0,held_input_addr}<add_oe) ||
        ({32'd0,held_output_addr}<add_be && {32'd0,held_weight_addr}<add_oe) ||
        ({32'd0,held_output_addr}<add_qe && {32'd0,held_quant_addr}<add_oe);
    wire cat_address_bad_raw=add_ae>64'h20000000 || cat_be>64'h20000000 || cat_oe>64'h20000000;
    wire cat_overlap_bad_raw=({32'd0,held_output_addr}<add_ae && {32'd0,held_input_addr}<cat_oe) ||
        ({32'd0,held_output_addr}<cat_be && {32'd0,held_weight_addr}<cat_oe);
    wire pool_address_bad_raw=add_ae>64'h20000000 || add_oe>64'h20000000;
    wire pool_overlap_bad_raw={32'd0,held_output_addr}<add_ae && {32'd0,held_input_addr}<add_oe;
    wire [63:0] up_oe={32'd0,held_output_addr}+(add_size<<2);
    wire up_address_bad_raw=add_ae>64'h20000000 || up_oe>64'h20000000;
    wire up_overlap_bad_raw={32'd0,held_output_addr}<add_ae && {32'd0,held_input_addr}<up_oe;
    wire [31:0] up_write_addr=output_addr+(up_channel<<1)+
        (up_copy[0] ? (ci_pitch<<1):32'd0)+(up_copy[1] ? up_row_bytes:32'd0);
    wire signed [31:0] pool_iy=$signed(pool_y)+$signed({29'd0,pool_ky})-32'sd2;
    wire signed [31:0] pool_ix=$signed(pool_x)+$signed({29'd0,pool_kx})-32'sd2;
    wire pool_inside=pool_iy>=0 && pool_ix>=0 && pool_iy<$signed({16'd0,height}) && pool_ix<$signed({16'd0,width});
    reg [127:0] pool_output;
    integer pool_lane;
    always @* begin
        pool_output=pool_max;
        for(pool_lane=0;pool_lane<8;pool_lane=pool_lane+1)
            if(pool_channel+pool_lane>={16'd0,input_channels})pool_output[pool_lane*16 +: 16]=0;
    end
    wire [31:0] cat_out_channel=cat_channel+{29'd0,cat_lane};
    wire cat_source_b=cat_out_channel>={16'd0,input_channels};
    wire [31:0] cat_source_channel=cat_source_b ? cat_out_channel-{16'd0,input_channels}:cat_out_channel;
    // 每个像素完成后推进基址，供数路径不需要逐元素计算像素索引乘通道间距。
    wire [31:0] cat_source_addr=(cat_source_b ? weight_addr:input_addr)+(cat_source_channel&32'hfffffff8)*2;
    wire [31:0] cat_output_addr=output_addr+cat_channel*2;
    wire address_bad_raw=ie>64'h20000000 || we>64'h20000000 || oe>64'h20000000 ||
        (held_bias_enable && be>64'h20000000) || (cfg_quantized && quant_end>64'h20000000);
    // 只读区域允许相互重叠；输出禁止覆盖任意正在读取的区域。
    wire overlap_bad_raw=({32'd0,held_output_addr}<ie && {32'd0,held_input_addr}<oe) ||
        ({32'd0,held_output_addr}<we && {32'd0,held_weight_addr}<oe) ||
        (held_bias_enable && {32'd0,held_output_addr}<be && {32'd0,held_bias_addr}<oe) ||
        (cfg_quantized && {32'd0,held_output_addr}<quant_end && {32'd0,held_quant_addr}<oe);
    reg address_bad,overlap_bad,add_address_bad,add_overlap_bad,cat_address_bad,cat_overlap_bad,pool_address_bad,pool_overlap_bad,up_address_bad,up_overlap_bad;
    wire [3:0] ty=taps==1 ? 4'd0 : tap/4'd3, tx=taps==1 ? 4'd0 : tap%4'd3;
    wire signed [31:0] iy=$signed(stride==2 ? y<<1 : y)+$signed({28'd0,ty})-$signed({30'd0,padding});
    wire [31:0] ox=x_tile+{29'd0,pixel};
    wire signed [31:0] ix=$signed(stride==2 ? ox<<1 : ox)+$signed({28'd0,tx})-$signed({30'd0,padding});
    wire inside_image=iy>=0 && ix>=0 && iy<$signed({16'd0,height}) && ix<$signed({16'd0,width});
    wire lane_valid=co_base+{30'd0,weight_lane}<{16'd0,output_channels};
    wire [31:0] next_tile_remaining=out_w-x_tile-32'd4;
    wire first_output_group=ACT_WIDTH==16 ? !co_base[2] : co_base[3:0]==0;
    // INT16按16通道分配；最后只有前8通道被覆盖时，额外清零后一个DDR字。
    wire pad_tail=ACT_WIDTH==16 && co_base+4>={16'd0,output_channels} &&
        (({16'd0,output_channels}+32'd7)&32'hfffffff8)<output_pitch;
    wire creq_ready, crsp_valid, crsp_error;
    wire [3:0] crsp_code;
    wire [255:0] crsp_data;
    reg [127:0] up_input;
    integer up_lane;
    always @* begin
        up_input=crsp_data[127:0];
        for(up_lane=0;up_lane<8;up_lane=up_lane+1)
            if(up_channel+up_lane>={16'd0,input_channels})up_input[up_lane*16 +: 16]=0;
    end
    wire raw_creq_valid=(state==B_REQ || (state==W_REQ && lane_valid) ||
        (state==P_REQ && inside_image) || state==O_REQ || state==MERGE_REQ || state==PAD_REQ ||
        state==ADD_QREQ || state==ADD_AREQ || state==ADD_BREQ || state==ADD_OREQ || state==CAT_REQ || state==CAT_OREQ ||
        state==POOL_REQ || state==POOL_OREQ || state==UP_REQ || state==UP_OREQ ||
        (state==QPAR_REQ && co_base+{30'd0,quant_lane}<{16'd0,output_channels}));
    // Address operands are captured once per request. The engine remains in
    // its request state until the registered address and DDR client are ready.
    wire address_required=(state==W_REQ && lane_valid) || (state==P_REQ && inside_image) ||
        state==O_REQ || state==MERGE_REQ || state==PAD_REQ;
    wire address_in_ready,address_valid;
    wire [31:0] request_address;
    wire address_weight=state==W_REQ,address_input=state==P_REQ;
    wire [31:0] address_a=address_weight?co_base+{30'd0,weight_lane}:address_input?$unsigned(iy):y;
    wire [31:0] address_b=address_weight?{28'd0,taps}:address_input?{16'd0,width}:out_w;
    wire [31:0] address_index=address_weight?{28'd0,tap}:address_input?$unsigned(ix):ox;
    wire [31:0] address_pitch=(address_weight || address_input)?ci_pitch:quantized?output_pitch:co_pitch;
    wire [31:0] address_inner=(address_weight || address_input)?ci_base:
        quantized?(co_base&(ACT_WIDTH==16?32'hfffffff8:32'hfffffff0)):co_base;
    wire [31:0] address_base=address_weight?weight_addr:address_input?input_addr:
        output_addr+(state==PAD_REQ?32'd16:32'd0);
    wire [1:0] address_shift=address_weight?2'd0:address_input?(ACT_WIDTH==16?2'd1:2'd0):
        quantized?(ACT_WIDTH==16?2'd1:2'd0):2'd3;
    ai_address_math u_address(
        .clk(clk),.rst_n(rst_n),.clear(state==IDLE),.in_valid(address_required),.in_ready(address_in_ready),
        .a(address_a),.b(address_b),.index_add(address_index),.pitch(address_pitch),.inner(address_inner),
        .base(address_base),.element_shift(address_shift),.out_valid(address_valid),
        .out_ready(address_required && creq_ready),.address(request_address));
    wire unused_address_ready=address_in_ready;
    wire creq_valid=raw_creq_valid && (!address_required || address_valid);
    wire [31:0] creq_addr=state==B_REQ ? bias_addr+co_base*4 :
        state==W_REQ ? request_address : state==P_REQ ? request_address :
        state==QPAR_REQ ? quant_addr+(co_base+{30'd0,quant_lane})*(ACT_WIDTH==16 ? 32'd32 : 32'd16) :
        state==ADD_QREQ ? quant_addr:state==ADD_AREQ ? input_addr+add_offset:
        state==ADD_BREQ ? weight_addr+add_offset:state==ADD_OREQ ? output_addr+add_offset:
        state==CAT_REQ ? cat_read_addr:state==CAT_OREQ ? cat_output_addr:
        state==POOL_REQ ? pool_tap_addr:state==POOL_OREQ ? output_addr:
        state==UP_REQ ? input_addr+(up_channel<<1):state==UP_OREQ ? up_write_addr:
        request_address;
    wire load_ready, tile_start_ready, tile_out_valid, tile_error, tile_busy, issue;
    wire tile_cache_ready,tile_start_ready_raw;
    reg cache_pending,cache_weight;
    reg [1:0] cache_lane;
    reg [3:0] cache_tap;
    reg [16*ACT_WIDTH-1:0] cache_payload;
    assign load_ready=!cache_pending || tile_cache_ready;
    assign tile_start_ready=tile_start_ready_raw && !cache_pending;
    // Payload and cache tags advance together; start waits for the final load.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin cache_pending<=0;cache_weight<=0;cache_lane<=0;cache_tap<=0;cache_payload<=0;end
        else if(state==IDLE)cache_pending<=0;
        else if(load_ready)begin
            cache_pending<=tile_load_valid;
            if(tile_load_valid)begin
                cache_weight<=state==W_REQ || state==W_WAIT;
                cache_lane<=weight_lane;cache_tap<=tap;cache_payload<=cache_data;
            end
        end
    end
    wire [255:0] tile_result;
    wire tile_load_valid=(state==W_REQ && !lane_valid) || (state==P_REQ && !inside_image) ||
        ((state==W_WAIT || state==P_WAIT) && crsp_valid && !crsp_error);
    wire crsp_ready=(state==B_WAIT || state==O_WAIT || state==QPAR_WAIT || state==MERGE_WAIT || state==PAD_WAIT ||
        state==ADD_QWAIT || state==ADD_AWAIT || state==ADD_BWAIT || state==ADD_OWAIT || state==CAT_WAIT || state==CAT_OWAIT) ||
        state==POOL_WAIT || state==POOL_OWAIT || state==UP_WAIT || state==UP_OWAIT ||
        ((state==W_WAIT || state==P_WAIT) && (crsp_error || load_ready));
    reg [16*ACT_WIDTH-1:0] patch_data;
    integer mask_byte;
    always @* begin
        patch_data=crsp_data[16*ACT_WIDTH-1:0];
        for(mask_byte=0;mask_byte<16;mask_byte=mask_byte+1)
            if(ci_base+mask_byte>={16'd0,input_channels}) patch_data[mask_byte*ACT_WIDTH +: ACT_WIDTH]=0;
    end
    wire [16*ACT_WIDTH-1:0] cache_data=(state==W_REQ || state==P_REQ) ? {(16*ACT_WIDTH){1'b0}} :
        state==P_WAIT ? patch_data : {{(16*ACT_WIDTH-128){1'b0}},crsp_data[127:0]};
    assign cmd_ready=rst_n && state==IDLE && !dma_fault && dma_initialized;
    assign busy=state!=IDLE;
    // 每个DDR字的第一组从全零开始；后续4通道组读改写已有结果。
    // 这样无需整图片上缓存，也不要求 CPU 预清输出；代价是额外 DDR 流量。
    reg [127:0] packed_output;
    always @* begin
        packed_output=first_output_group ? 128'd0 : merge_word;
        packed_output[(ACT_WIDTH==16 ? {31'd0,co_base[2]} : {30'd0,co_base[3:2]})*(4*ACT_WIDTH) +: 4*ACT_WIDTH]=quant_pixels[pixel[1:0]];
    end
    wire quant_in_ready, quant_out_valid, quant_error;
    wire [ACT_WIDTH-1:0] quant_data;
    generate if(ACT_WIDTH==8) begin : g_quant8
    wire unused_high=|crsp_data[255:128];
    wire unused_wide_params=^quant_multiplier1[quant_lane] ^ ^quant_shift1[quant_lane] ^
        ^quant_multiplier_y[quant_lane] ^ ^quant_shift_y[quant_lane];
    requant_int8 u_requant (
        .clk(clk),.rst_n(rst_n),.in_valid(state==Q_START),.in_ready(quant_in_ready),
        .in_sum(partials[pixel[1:0]][quant_lane*64 +: 64]),
        .multiplier(quant_multiplier[quant_lane]),.shift(quant_shift[quant_lane]),.relu(relu_enable),
        .out_valid(quant_out_valid),.out_ready(state==Q_WAIT),.out_data(quant_data),.out_error(quant_error)
    );
    end else begin : g_quant16
    wire unused_clamped;
    requant_q13 u_requant (
        .clk(clk),.rst_n(rst_n),.in_valid(state==Q_START),.in_ready(quant_in_ready),
        .in_sum0(partials[pixel[1:0]][quant_lane*64 +: 64]),
        .in_sum1(partials1[pixel[1:0]][quant_lane*64 +: 64]),.group1_enable(group_split!=0),
        .mult_m0(quant_multiplier[quant_lane]),.shift_m0(quant_shift[quant_lane]),
        .mult_m1(quant_multiplier1[quant_lane]),.shift_m1(quant_shift1[quant_lane]),
        .bias_q13(bias_enable ? biases[quant_lane*32 +: 32] : 32'd0),
        .mult_y(quant_multiplier_y[quant_lane]),.shift_y(quant_shift_y[quant_lane]),.relu(relu_enable),
        .out_valid(quant_out_valid),.out_ready(state==Q_WAIT),.out_data(quant_data),.out_error(quant_error),
        .out_clamped(unused_clamped)
    );
    end endgenerate
    wire add_in_ready,add_out_valid,add_error;
    wire [15:0] add_data;
    wire add_lane_valid=add_channel+{29'd0,add_lane}<{16'd0,input_channels};
    generate if(ACT_WIDTH==16)begin : g_add
        add_int16 u_add (
            .clk(clk),.rst_n(rst_n),.in_valid(state==ADD_START),.in_ready(add_in_ready),
            .in_a(add_lane_valid ? add_word_a[add_lane*16 +: 16]:16'd0),
            .in_b(add_lane_valid ? add_word_b[add_lane*16 +: 16]:16'd0),
            .mult_a(add_mult_a),.shift_a(add_shift_a),.mult_b(add_mult_b),.shift_b(add_shift_b),
            .out_valid(add_out_valid),.out_ready(state==ADD_WAIT),.out_data(add_data),.out_error(add_error)
        );
    end else begin : g_no_add
        wire unused_add=add_lane_valid ^ ^add_word_a ^ ^add_word_b ^ ^add_mult_a ^ ^add_shift_a ^ ^add_mult_b ^ ^add_shift_b;
        assign add_in_ready=0;assign add_out_valid=0;assign add_error=0;assign add_data=0;
    end endgenerate
    ddr_chunk_client u_client (
        .clk(clk), .rst_n(rst_n), .req_valid(creq_valid), .req_ready(creq_ready),
        .req_write(state==O_REQ || state==PAD_REQ || state==ADD_OREQ || state==CAT_OREQ || state==POOL_OREQ || state==UP_OREQ),
        .req_two((state==O_REQ && !quantized) || (ACT_WIDTH==16 && (state==P_REQ || state==QPAR_REQ))), .req_addr(creq_addr),
        .req_data(state==UP_OREQ ? {128'd0,up_word}:state==POOL_OREQ ? {128'd0,pool_output}:
            state==CAT_OREQ ? {128'd0,cat_word}:state==ADD_OREQ ? {128'd0,add_word_out}:
            state==PAD_REQ ? 256'd0 : quantized ? {128'd0,packed_output} : partials[pixel[1:0]]),
        .rsp_valid(crsp_valid), .rsp_ready(crsp_ready),
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
    conv_mac_tile #(.ACT_WIDTH(ACT_WIDTH),.REDUCE_PAIRS(ACT_WIDTH==16?2:1)) u_tile (
        .clk(clk), .rst_n(rst_n), .load_valid(cache_pending), .load_ready(tile_cache_ready),
        .load_weight(cache_weight), .load_lane(cache_lane), .load_tap(cache_tap), .load_data(cache_payload),
        .start_valid(state==T_START && !cache_pending), .start_ready(tile_start_ready_raw), .tap_count(taps),
        .initial_sums(current_group ? partials1[pixel[1:0]] : partials[pixel[1:0]]),
        .compute_enable(1'b1), .busy(tile_busy), .error(tile_error),
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
    task next_quant_param;
        begin
            if(quant_lane==3) begin quant_lane<=0; state<=bias_enable ? B_REQ : INIT; end
            else begin quant_lane<=quant_lane+1'b1; state<=QPAR_REQ; end
        end
    endtask
    task next_quant_value;
        begin
            if(quant_lane!=3) begin quant_lane<=quant_lane+1'b1; state<=Q_START; end
            else begin
                quant_lane<=0;
                if(pixel+3'd1<tile_width) begin pixel<=pixel+1'b1; state<=Q_START; end
                else begin pixel<=0; state<=first_output_group ? O_REQ : MERGE_REQ; end
            end
        end
    endtask
    task next_output;
        begin
            if(pixel+3'd1<tile_width) begin
                pixel<=pixel+1'b1; state<=quantized && !first_output_group ? MERGE_REQ : O_REQ;
            end else if(x_tile+32'd4<out_w) begin
                x_tile<=x_tile+32'd4;
                tile_width<=next_tile_remaining>=4 ? 3'd4 : next_tile_remaining[2:0]; state<=INIT;
            end else if(y+1<out_h) begin
                x_tile<=0;y<=y+1'b1;tile_width<=out_w>=4 ? 3'd4:out_w[2:0];state<=INIT;
            end else if(co_base+32'd4<{16'd0,output_channels}) begin
                co_base<=co_base+32'd4;y<=0;x_tile<=0;tile_width<=out_w>=4 ? 3'd4:out_w[2:0];
                biases<=0;quant_lane<=0;state<=quantized ? QPAR_REQ:(bias_enable ? B_REQ:INIT);
            end else begin state<=IDLE;done<=1;end
        end
    endtask
    task next_cat_lane;
        begin
            if(cat_lane==7)state<=CAT_OREQ;
            else begin cat_lane<=cat_lane+1'b1;state<=CAT_PREP;end
        end
    endtask
    task next_pool_tap;
        begin
            if(pool_kx!=4)begin
                pool_kx<=pool_kx+1'b1;pool_tap_addr<=pool_tap_addr+(ci_pitch<<1);state<=POOL_PREP;
            end else if(pool_ky!=4)begin
                pool_kx<=0;pool_ky<=pool_ky+1'b1;
                pool_tap_row_addr<=pool_tap_row_addr+pool_row_bytes;
                pool_tap_addr<=pool_tap_row_addr+pool_row_bytes;state<=POOL_PREP;
            end else state<=POOL_OREQ;
        end
    endtask
    integer i,j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; done<=0; error<=0; error_code<=0;
            held_opcode<=0;
            held_input_addr<=0;
            held_weight_addr<=0;
            held_bias_addr<=0;
            held_output_addr<=0;
            held_quant_addr<=0;
            held_post<=0;
            held_group_split<=0;
            held_in_h<=0;
            held_in_w<=0;
            held_in_ch<=0;
            held_out_ch<=0;
            held_kernel<=0;
            held_stride<=0;
            held_padding<=0;
            held_bias_enable<=0;
            cfg_ci_pitch<=0;cfg_co_pitch<=0;cfg_output_pitch<=0;cfg_cat_b_pitch<=0;
            padded_h<=0;padded_w<=0;calc_h<=0;calc_w<=0;
            address_bad<=0;overlap_bad<=0;add_address_bad<=0;add_overlap_bad<=0;cat_address_bad<=0;cat_overlap_bad<=0;pool_address_bad<=0;pool_overlap_bad<=0;up_address_bad<=0;up_overlap_bad<=0;
            ie<=0;we<=0;be<=0;oe<=0;quant_end<=0;add_ae<=0;add_be<=0;add_oe<=0;add_qe<=0;cat_be<=0;cat_oe<=0;

            input_addr<=0; weight_addr<=0; bias_addr<=0; output_addr<=0;
            quant_addr<=0; output_pitch<=0; output_int8<=0; relu_enable<=0; quant_lane<=0; merge_word<=0;group_split<=0;
            height<=0; width<=0; input_channels<=0; output_channels<=0;
            ci_pitch<=0; co_pitch<=0; ci_base<=0; co_base<=0; y<=0; x_tile<=0;
            stride<=1; padding<=0; weight_lane<=0; taps<=1; tap<=0; bias_enable<=0;
            pixel<=0; tile_width<=0; biases<=0; out_h<=0; out_w<=0; total_cycles<=0; mac_issues<=0;
            add_offset<=0;add_bytes<=0;add_channel<=0;add_lane<=0;
            add_mult_a<=0;add_shift_a<=0;add_mult_b<=0;add_shift_b<=0;add_word_a<=0;add_word_b<=0;add_word_out<=0;
            cat_x<=0;cat_y<=0;cat_channel<=0;cat_lane<=0;cat_read_addr<=0;cat_cache_addr<=0;
            cat_cache_valid<=0;cat_cache<=0;cat_word<=0;
            pool_x<=0;pool_y<=0;pool_channel<=0;pool_pixel_addr<=0;pool_row_bytes<=0;
            pool_tap_row_addr<=0;pool_tap_addr<=0;pool_kx<=0;pool_ky<=0;pool_max<=0;
            up_x<=0;up_y<=0;up_channel<=0;up_row_bytes<=0;up_copy<=0;up_word<=0;
            for(i=0;i<4;i=i+1) begin
                partials[i]<=0;partials1[i]<=0;quant_multiplier[i]<=0;quant_shift[i]<=0;quant_pixels[i]<=0;
                quant_multiplier1[i]<=0;quant_shift1[i]<=0;quant_multiplier_y[i]<=0;quant_shift_y[i]<=0;
            end
        end else begin
            if(busy) total_cycles<=total_cycles+1'b1;
            if(issue) mac_issues<=mac_issues+(ACT_WIDTH==16?32'd2:32'd1);
            if(state==IDLE && clear_status) begin done<=0; error<=0; error_code<=0; end
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    held_opcode<=cfg_opcode;
                    held_input_addr<=cfg_input_addr;
                    held_weight_addr<=cfg_weight_addr;
                    held_bias_addr<=cfg_bias_addr;
                    held_output_addr<=cfg_output_addr;
                    held_quant_addr<=cfg_quant_addr;
                    held_post<=cfg_post;
                    held_group_split<=cfg_group_split;
                    held_in_h<=cfg_in_h;
                    held_in_w<=cfg_in_w;
                    held_in_ch<=cfg_in_ch;
                    held_out_ch<=cfg_out_ch;
                    held_kernel<=cfg_kernel;
                    held_stride<=cfg_stride;
                    held_padding<=cfg_padding;
                    held_bias_enable<=cfg_bias_enable;
                    done<=0;error<=0;error_code<=0;total_cycles<=0;mac_issues<=0;out_h<=0;out_w<=0;
                    state<=CFG_PITCH;
                end
                CFG_PITCH:begin
                    cfg_ci_pitch<=({16'd0,held_in_ch}+32'd15)&32'hfffffff0;
                    cfg_co_pitch<=({16'd0,held_out_ch}+32'd3)&32'hfffffffc;
                    cfg_output_pitch<=cfg_quantized?(({16'd0,held_out_ch}+32'd15)&32'hfffffff0):
                        (({16'd0,held_out_ch}+32'd3)&32'hfffffffc);
                    cfg_cat_b_pitch<=(held_group_split+32'd15)&32'hfffffff0;
                    padded_h<={16'd0,held_in_h}+({30'd0,held_padding}<<1);
                    padded_w<={16'd0,held_in_w}+({30'd0,held_padding}<<1);
                    state<=CFG_DIMS;
                end
                CFG_DIMS:begin
                    calc_h<=((padded_h-{30'd0,held_kernel})>>(held_stride==2))+1;
                    calc_w<=((padded_w-{30'd0,held_kernel})>>(held_stride==2))+1;
                    state<=CFG_START;
                end
                CFG_START:state<=CFG_WAIT;
                CFG_WAIT:if(sizes_done)state<=CFG_END;
                CFG_END:begin
                    ie<={32'd0,held_input_addr}+input_size;we<={32'd0,held_weight_addr}+weight_size;
                    be<={32'd0,held_bias_addr}+({32'd0,cfg_co_pitch}<<2);
                    oe<={32'd0,held_output_addr}+output_size;
                    quant_end<={32'd0,held_quant_addr}+({32'd0,cfg_co_pitch}<<(ACT_WIDTH==16?5:4));
                    add_ae<={32'd0,held_input_addr}+add_size;add_be<={32'd0,held_weight_addr}+add_size;
                    add_oe<={32'd0,held_output_addr}+add_size;add_qe<={32'd0,held_quant_addr}+64'd16;
                    cat_be<={32'd0,held_weight_addr}+cat_b_size;cat_oe<={32'd0,held_output_addr}+cat_o_size;
                    state<=CFG_VALIDATE;
                end
                // Separate wide region comparisons from dispatch/register enables.
                CFG_VALIDATE:begin
                    address_bad<=address_bad_raw;overlap_bad<=overlap_bad_raw;add_address_bad<=add_address_bad_raw;add_overlap_bad<=add_overlap_bad_raw;cat_address_bad<=cat_address_bad_raw;cat_overlap_bad<=cat_overlap_bad_raw;pool_address_bad<=pool_address_bad_raw;pool_overlap_bad<=pool_overlap_bad_raw;up_address_bad<=up_address_bad_raw;up_overlap_bad<=up_overlap_bad_raw;
                    state<=CFG_CHECK;
                end
                CFG_CHECK:begin
                    // Invalid commands complete without issuing any DDR request.
                    // Valid branches below override this default transition.
                    state<=IDLE;
                    if(held_opcode==5)begin
                        if(ACT_WIDTH!=16 || held_post!=4 || held_weight_addr!=0 || held_bias_addr!=0 || held_quant_addr!=0 ||
                            held_group_split!=0 || held_kernel!=0 || held_stride!=0 || held_padding!=0 || held_bias_enable)begin error<=1;error_code<=7;end
                        // 倍增后的高宽仍要能装进下一条任务的16位尺寸字段。
                        else if(held_in_h==0 || held_in_w==0 || held_in_h>32767 || held_in_w>32767 ||
                            held_in_ch==0 || held_out_ch!=held_in_ch)begin error<=1;error_code<=1;end
                        else if((held_input_addr[3:0]|held_output_addr[3:0])!=0)begin error<=1;error_code<=4;end
                        else if(up_address_bad)begin error<=1;error_code<=3;end
                        else if(up_overlap_bad)begin error<=1;error_code<=5;end
                        else begin
                            input_addr<=held_input_addr;output_addr<=held_output_addr;ci_pitch<=cfg_ci_pitch;
                            height<=held_in_h;width<=held_in_w;input_channels<=held_in_ch;
                            out_h<=({16'd0,held_in_h}<<1);out_w<=({16'd0,held_in_w}<<1);
                            up_x<=0;up_y<=0;up_channel<=0;up_copy<=0;up_word<=0;
                            up_row_bytes<={16'd0,held_in_w}*(cfg_ci_pitch<<2);state<=UP_PREP;
                        end
                    end else if(held_opcode==4)begin
                        // 固定K5/S1/P2；不用卷积位域表达5，未使用的字段必须清零。
                        if(ACT_WIDTH!=16 || held_post!=4 || held_weight_addr!=0 || held_bias_addr!=0 || held_quant_addr!=0 ||
                            held_group_split!=0 || held_kernel!=0 || held_stride!=0 || held_padding!=0 || held_bias_enable)begin error<=1;error_code<=7;end
                        else if(held_in_h==0 || held_in_w==0 || held_in_ch==0 || held_out_ch!=held_in_ch)begin error<=1;error_code<=1;end
                        else if((held_input_addr[3:0]|held_output_addr[3:0])!=0)begin error<=1;error_code<=4;end
                        else if(pool_address_bad)begin error<=1;error_code<=3;end
                        else if(pool_overlap_bad)begin error<=1;error_code<=5;end
                        else begin
                            input_addr<=held_input_addr;output_addr<=held_output_addr;ci_pitch<=cfg_ci_pitch;
                            height<=held_in_h;width<=held_in_w;input_channels<=held_in_ch;
                            out_h<={16'd0,held_in_h};out_w<={16'd0,held_in_w};
                            pool_x<=0;pool_y<=0;pool_channel<=0;pool_pixel_addr<=held_input_addr;
                            pool_row_bytes<={16'd0,held_in_w}*(cfg_ci_pitch<<1);state<=POOL_INIT;
                        end
                    end else if(held_opcode==3)begin
                        // group_split在Concat中是B通道数，不是量化分组边界。
                        if(ACT_WIDTH!=16 || held_post!=4 || held_quant_addr!=0 || held_bias_addr!=0 ||
                            held_kernel!=0 || held_stride!=0 || held_padding!=0 || held_bias_enable)begin error<=1;error_code<=7;end
                        else if(held_in_h==0 || held_in_w==0 || held_in_ch==0 || held_group_split==0 || held_group_split>65535 ||
                            {16'd0,held_in_ch}+held_group_split!={16'd0,held_out_ch})begin error<=1;error_code<=1;end
                        else if((held_input_addr[3:0]|held_weight_addr[3:0]|held_output_addr[3:0])!=0)begin error<=1;error_code<=4;end
                        else if(cat_address_bad)begin error<=1;error_code<=3;end
                        else if(cat_overlap_bad)begin error<=1;error_code<=5;end
                        else begin
                            input_addr<=held_input_addr;weight_addr<=held_weight_addr;output_addr<=held_output_addr;
                            input_channels<=held_in_ch;output_channels<=held_out_ch;ci_pitch<=cfg_ci_pitch;co_pitch<=cfg_cat_b_pitch;
                            output_pitch<=cfg_output_pitch;out_h<={16'd0,held_in_h};out_w<={16'd0,held_in_w};
                            cat_x<=0;cat_y<=0;cat_channel<=0;cat_lane<=0;
                            cat_cache_valid<=0;cat_word<=0;state<=CAT_PREP;
                        end
                    end else if(held_opcode==2)begin
                        if(ACT_WIDTH!=16 || held_post!=4 || held_group_split!=0 || held_bias_addr!=0 ||
                            held_kernel!=0 || held_stride!=0 || held_padding!=0 || held_bias_enable)begin error<=1;error_code<=7;end
                        else if(held_in_h==0 || held_in_w==0 || held_in_ch==0 || held_out_ch!=held_in_ch)begin error<=1;error_code<=1;end
                        else if((held_input_addr[3:0]|held_weight_addr[3:0]|held_output_addr[3:0]|held_quant_addr[3:0])!=0)begin error<=1;error_code<=4;end
                        else if(add_address_bad)begin error<=1;error_code<=3;end
                        else if(add_overlap_bad)begin error<=1;error_code<=5;end
                        else begin
                            input_addr<=held_input_addr;weight_addr<=held_weight_addr;output_addr<=held_output_addr;quant_addr<=held_quant_addr;
                            input_channels<=held_in_ch;ci_pitch<=cfg_ci_pitch;out_h<={16'd0,held_in_h};out_w<={16'd0,held_in_w};
                            add_bytes<=add_size[31:0];add_offset<=0;add_channel<=0;add_lane<=0;add_word_out<=0;state<=ADD_QREQ;
                        end
                    end else if(held_opcode!=1)begin error<=1;error_code<=7;end
                    else if(held_in_h==0 || held_in_w==0 || held_in_ch==0 || held_out_ch==0) begin error<=1; error_code<=1; end
                    else if((held_kernel!=1 && held_kernel!=3) || (held_stride!=1 && held_stride!=2) || held_padding>1 ||
                        padded_h<{30'd0,held_kernel} || padded_w<{30'd0,held_kernel}) begin error<=1; error_code<=2; end
                    else if(held_input_addr[3:0]!=0 || held_weight_addr[3:0]!=0 || held_output_addr[3:0]!=0 ||
                        (held_bias_enable && held_bias_addr[3:0]!=0) ||
                        (cfg_quantized && held_quant_addr[3:0]!=0)) begin error<=1; error_code<=4; end
                    else if(ACT_WIDTH==8 ? (held_post[31:2]!=0 || (!held_post[0] && held_post[1])) :
                        ((held_post!=4 && held_post!=6) || (held_group_split!=0 &&
                            (held_group_split[3:0]!=0 || held_group_split>={16'd0,held_in_ch})))) begin error<=1; error_code<=7; end
                    else if(address_bad) begin error<=1; error_code<=3; end
                    else if(overlap_bad) begin error<=1; error_code<=5; end
                    else begin
                        input_addr<=held_input_addr; weight_addr<=held_weight_addr; bias_addr<=held_bias_addr; output_addr<=held_output_addr;
                        height<=held_in_h; width<=held_in_w; input_channels<=held_in_ch; output_channels<=held_out_ch;
                        ci_pitch<=cfg_ci_pitch; co_pitch<=cfg_co_pitch; stride<=held_stride; padding<=held_padding;
                        quant_addr<=held_quant_addr; output_pitch<=cfg_output_pitch;
                        output_int8<=held_post[0]; relu_enable<=held_post[1]; quant_lane<=0;group_split<=ACT_WIDTH==16 ? held_group_split:32'd0;
                        bias_enable<=held_bias_enable; taps<=held_kernel==3 ? 4'd9 : 4'd1;
                        out_h<=calc_h; out_w<=calc_w; ci_base<=0; co_base<=0; y<=0; x_tile<=0; pixel<=0; tap<=0; weight_lane<=0;
                        tile_width<=calc_w>=4 ? 3'd4 : calc_w[2:0]; biases<=0;
                        state<=cfg_quantized ? QPAR_REQ : (held_bias_enable ? B_REQ : INIT);
                    end
                end
                B_REQ: if(creq_valid && creq_ready) state<=B_WAIT;
                B_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin biases<=crsp_data[127:0]; state<=INIT; end
                QPAR_REQ: if(co_base+{30'd0,quant_lane}>={16'd0,output_channels}) begin
                        quant_multiplier[quant_lane]<=0;quant_shift[quant_lane]<=0;quant_multiplier1[quant_lane]<=0;
                        quant_shift1[quant_lane]<=0;quant_multiplier_y[quant_lane]<=0;quant_shift_y[quant_lane]<=0;next_quant_param;
                    end else if(creq_valid && creq_ready) state<=QPAR_WAIT;
                QPAR_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin
                    if(crsp_data[31] || crsp_data[63:32]>95 || (ACT_WIDTH==8 ? crsp_data[127:64]!=0 :
                        (crsp_data[159] || crsp_data[191:160]>95 || crsp_data[255:192]!=0 ||
                            (group_split!=0 && (crsp_data[95] || crsp_data[127:96]>95))))) begin
                        error<=1; error_code<=7; state<=IDLE;
                    end else begin
                        quant_multiplier[quant_lane]<=crsp_data[31:0];
                        quant_shift[quant_lane]<=crsp_data[63:32];
                        quant_multiplier1[quant_lane]<=crsp_data[95:64];quant_shift1[quant_lane]<=crsp_data[127:96];
                        quant_multiplier_y[quant_lane]<=crsp_data[159:128];quant_shift_y[quant_lane]<=crsp_data[191:160];next_quant_param;
                    end
                end
                INIT: begin
                    for(i=0;i<4;i=i+1) for(j=0;j<4;j=j+1)
                        partials[i][j*64 +: 64]<=ACT_WIDTH==8 && bias_enable && co_base+j<{16'd0,output_channels}
                            ? {{32{biases[j*32+31]}},biases[j*32 +: 32]} : 64'd0;
                    for(i=0;i<4;i=i+1) partials1[i]<=0;
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
                        if(current_group)partials1[pixel[1:0]]<=tile_result;else partials[pixel[1:0]]<=tile_result;
                        if(pixel+3'd1<tile_width) begin pixel<=pixel+1'b1; tap<=0; state<=P_REQ; end
                        else if(ci_base+32'd16<{16'd0,input_channels}) begin
                            ci_base<=ci_base+32'd16; pixel<=0; tap<=0; weight_lane<=0; state<=W_REQ;
                        end else begin pixel<=0; quant_lane<=0; state<=quantized ? Q_START : O_REQ; end
                    end
                // 无效通道使用先前装载的零参数，输出阶段仍显式补零。
                Q_START: if(quant_in_ready) state<=Q_WAIT;
                Q_WAIT: if(quant_out_valid) begin
                    if(quant_error) begin error<=1; error_code<=7; state<=IDLE; end
                    else begin
                        quant_pixels[pixel[1:0]][quant_lane*ACT_WIDTH +: ACT_WIDTH]<=
                            co_base+{30'd0,quant_lane}<{16'd0,output_channels} ? quant_data : {ACT_WIDTH{1'b0}};
                        next_quant_value;
                    end
                end
                MERGE_REQ: if(creq_valid && creq_ready) state<=MERGE_WAIT;
                MERGE_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin merge_word<=crsp_data[127:0]; state<=O_REQ; end
                O_REQ: if(creq_valid && creq_ready) state<=O_WAIT;
                O_WAIT: if(crsp_valid && crsp_ready && !crsp_error) begin
                    if(pad_tail)state<=PAD_REQ;else next_output;
                end
                PAD_REQ:if(creq_valid && creq_ready)state<=PAD_WAIT;
                PAD_WAIT:if(crsp_valid && crsp_ready && !crsp_error)next_output;
                ADD_QREQ:if(creq_valid && creq_ready)state<=ADD_QWAIT;
                ADD_QWAIT:if(crsp_valid && !crsp_error)begin
                    if(crsp_data[31] || crsp_data[95] || crsp_data[63:32]>63 || crsp_data[127:96]>63)begin
                        error<=1;error_code<=7;state<=IDLE;
                    end else begin
                        add_mult_a<=crsp_data[31:0];add_shift_a<=crsp_data[63:32];
                        add_mult_b<=crsp_data[95:64];add_shift_b<=crsp_data[127:96];state<=ADD_AREQ;
                    end
                end
                ADD_AREQ:if(creq_valid && creq_ready)state<=ADD_AWAIT;
                ADD_AWAIT:if(crsp_valid && !crsp_error)begin add_word_a<=crsp_data[127:0];state<=ADD_BREQ;end
                ADD_BREQ:if(creq_valid && creq_ready)state<=ADD_BWAIT;
                ADD_BWAIT:if(crsp_valid && !crsp_error)begin add_word_b<=crsp_data[127:0];add_lane<=0;add_word_out<=0;state<=ADD_START;end
                ADD_START:if(add_in_ready)state<=ADD_WAIT;
                ADD_WAIT:if(add_out_valid)begin
                    if(add_error)begin error<=1;error_code<=7;state<=IDLE;end
                    else begin
                        add_word_out[add_lane*16 +: 16]<=add_lane_valid ? add_data:16'd0;
                        if(add_lane==7)state<=ADD_OREQ;else begin add_lane<=add_lane+1'b1;state<=ADD_START;end
                    end
                end
                ADD_OREQ:if(creq_valid && creq_ready)state<=ADD_OWAIT;
                ADD_OWAIT:if(crsp_valid && !crsp_error)begin
                    if(add_offset+32'd16>=add_bytes)begin state<=IDLE;done<=1;end
                    else begin
                        add_offset<=add_offset+32'd16;
                        add_channel<=add_channel+32'd8>=ci_pitch ? 32'd0:add_channel+32'd8;state<=ADD_AREQ;
                    end
                end
                CAT_PREP:begin
                    if(cat_out_channel>={16'd0,output_channels})begin
                        cat_word[cat_lane*16 +: 16]<=0;next_cat_lane;
                    end else if(cat_cache_valid && cat_cache_addr==cat_source_addr)state<=CAT_COPY;
                    else begin cat_read_addr<=cat_source_addr;state<=CAT_REQ;end
                end
                CAT_REQ:if(creq_valid && creq_ready)state<=CAT_WAIT;
                CAT_WAIT:if(crsp_valid && !crsp_error)begin
                    cat_cache<=crsp_data[127:0];cat_cache_addr<=cat_read_addr;cat_cache_valid<=1;state<=CAT_COPY;
                end
                CAT_COPY:begin cat_word[cat_lane*16 +: 16]<=cat_cache[cat_source_channel[2:0]*16 +: 16];next_cat_lane;end
                CAT_OREQ:if(creq_valid && creq_ready)state<=CAT_OWAIT;
                CAT_OWAIT:if(crsp_valid && !crsp_error)begin
                    if(cat_channel+32'd8<output_pitch)begin
                        cat_channel<=cat_channel+32'd8;cat_lane<=0;cat_word<=0;state<=CAT_PREP;
                    end else if(cat_x+32'd1<out_w || cat_y+32'd1<out_h)begin
                        if(cat_x+32'd1<out_w)cat_x<=cat_x+32'd1;
                        else begin cat_x<=0;cat_y<=cat_y+32'd1;end
                        input_addr<=input_addr+(ci_pitch<<1);weight_addr<=weight_addr+(co_pitch<<1);output_addr<=output_addr+(output_pitch<<1);
                        cat_channel<=0;cat_lane<=0;cat_word<=0;state<=CAT_PREP;
                    end else begin state<=IDLE;done<=1;end
                end
                POOL_INIT:begin
                    pool_max<={8{16'h8000}};pool_kx<=0;pool_ky<=0;
                    // 越界邻域的地址允许无符号回绕，但POOL_PREP保证不发起其DDR读取。
                    pool_tap_addr<=pool_pixel_addr-(pool_row_bytes<<1)-(ci_pitch<<2)+(pool_channel<<1);
                    pool_tap_row_addr<=pool_pixel_addr-(pool_row_bytes<<1)-(ci_pitch<<2)+(pool_channel<<1);
                    state<=POOL_PREP;
                end
                POOL_PREP:begin
                    if(pool_channel>={16'd0,input_channels})state<=POOL_OREQ;
                    else if(!pool_inside)next_pool_tap;
                    else state<=POOL_REQ;
                end
                POOL_REQ:if(creq_valid && creq_ready)state<=POOL_WAIT;
                POOL_WAIT:if(crsp_valid && !crsp_error)begin
                    for(i=0;i<8;i=i+1)
                        if($signed(crsp_data[i*16 +: 16])>$signed(pool_max[i*16 +: 16]))
                            pool_max[i*16 +: 16]<=crsp_data[i*16 +: 16];
                    next_pool_tap;
                end
                POOL_OREQ:if(creq_valid && creq_ready)state<=POOL_OWAIT;
                POOL_OWAIT:if(crsp_valid && !crsp_error)begin
                    output_addr<=output_addr+32'd16;
                    if(pool_channel+32'd8<ci_pitch)begin pool_channel<=pool_channel+32'd8;state<=POOL_INIT;end
                    else if(pool_x+32'd1<out_w || pool_y+32'd1<out_h)begin
                        pool_channel<=0;pool_pixel_addr<=pool_pixel_addr+(ci_pitch<<1);
                        if(pool_x+32'd1<out_w)pool_x<=pool_x+32'd1;
                        else begin pool_x<=0;pool_y<=pool_y+32'd1;end
                        state<=POOL_INIT;
                    end else begin state<=IDLE;done<=1;end
                end
                UP_PREP:begin
                    up_copy<=0;
                    if(up_channel>={16'd0,input_channels})begin up_word<=0;state<=UP_OREQ;end
                    else state<=UP_REQ;
                end
                UP_REQ:if(creq_valid && creq_ready)state<=UP_WAIT;
                UP_WAIT:if(crsp_valid && !crsp_error)begin up_word<=up_input;state<=UP_OREQ;end
                UP_OREQ:if(creq_valid && creq_ready)state<=UP_OWAIT;
                UP_OWAIT:if(crsp_valid && !crsp_error)begin
                    if(up_copy!=3)begin up_copy<=up_copy+1'b1;state<=UP_OREQ;end
                    else if(up_channel+32'd8<ci_pitch)begin up_channel<=up_channel+32'd8;state<=UP_PREP;end
                    else if(up_x+32'd1<{16'd0,width} || up_y+32'd1<{16'd0,height})begin
                        input_addr<=input_addr+(ci_pitch<<1);up_channel<=0;
                        // 横向跨两个输出像素；换输入行时额外跳过一个输出行。
                        output_addr<=output_addr+(ci_pitch<<2)+(up_x+32'd1<{16'd0,width} ? 32'd0:up_row_bytes);
                        if(up_x+32'd1<{16'd0,width})up_x<=up_x+32'd1;
                        else begin up_x<=0;up_y<=up_y+32'd1;end
                        state<=UP_PREP;
                    end else begin state<=IDLE;done<=1;end
                end
                default: begin state<=IDLE; error<=1; error_code<=6; end
            endcase
            if(crsp_valid && crsp_ready && crsp_error) begin
                state<=IDLE; done<=0; error<=1; error_code<=4'h8 | crsp_code;
            end
        end
    end
    // synthesis translate_off
    initial if(ACT_WIDTH!=8 && ACT_WIDTH!=16)$fatal(1,"conv2d_ddr_engine ACT_WIDTH must be 8 or 16");
    // synthesis translate_on
endmodule
`default_nettype wire
