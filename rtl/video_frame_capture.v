`default_nettype none
`timescale 1ns/1ps
// 按需抓取一帧原始 RGB888，存为小端 R/G/B/0；此模块不包含 HDMI 芯片配置或缩放。
// core_clk 域接收命令并驱动通用 DMA；pixel_clk 域等待下一帧，逐行打包像素。
// 命令邮箱直到完成保持稳定，返回邮箱通过翻转位确认。共同复位时也须复位 DDR IP。
module video_frame_capture #(
    parameter integer FIFO_ADDR_BITS = 9,
    parameter integer DDR_ADDR_WIDTH = 28
)(
    input wire core_clk, rst_n, ddr_initialized,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [31:0] cfg_base, cfg_stride, cfg_timeout,
    input wire [15:0] cfg_width, cfg_height,
    input wire cfg_vs_active,
    output reg done, error, fault,
    output reg [3:0] error_code,
    output reg [31:0] written_bytes,
    input wire pixel_clk, pixel_vs, pixel_de,
    input wire [23:0] pixel_rgb,
    output wire dma_cmd_valid,
    input wire dma_cmd_ready,
    output wire [31:0] dma_cmd_addr, dma_cmd_len,
    output wire dma_wr_valid,
    input wire dma_wr_ready,
    output wire [127:0] dma_wr_data,
    input wire dma_done, dma_error, dma_fault
);
    localparam [3:0] E_SHAPE=1,E_ALIGN=2,E_RANGE=3,E_FRAME=4,E_OVERFLOW=5,E_TIMEOUT=6,E_DDR=7;
    localparam [2:0] S_IDLE=0,S_WAIT=1,S_SEND=2,S_WRITE=3,S_DROP=4,S_FAULT=5;
    localparam [1:0] P_IDLE=0,P_WAIT=1,P_FRAME=2;
    localparam [63:0] CAPACITY = 64'd1 << (DDR_ADDR_WIDTH+1);
    reg [2:0] state;
    // 原生 DMA 每块至多 16 拍；独立 FIFO 用来吸收不可背压的视频输入。
    reg [31:0] stride, timeout_limit, timer;
    reg [15:0] width, height;
    reg vs_active;
    reg request_toggle, cancel;
    reg [15:0] row, row_beats, row_cursor;
    reg [4:0] chunk_beats, chunk_sent;
    reg [31:0] row_address, consumed;
    reg pixel_finished, aborting, fatal_pending;
    reg [3:0] pending_code;
    reg [31:0] produced_limit;
    wire [63:0] command_row_bytes = (({48'd0,cfg_width}+64'd3)>>2)<<4;
    wire [63:0] command_end = {32'd0,cfg_base} +
                          ({48'd0,cfg_height}-64'd1)*{32'd0,cfg_stride} + command_row_bytes;

    /* verilator lint_off SYNCASYNCNET */
    (* ASYNC_REG="TRUE" *) reg [1:0] pixel_reset_sync;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n) pixel_reset_sync<=0;
        else pixel_reset_sync<={pixel_reset_sync[0],1'b1};
    wire pixel_reset_n=pixel_reset_sync[1];
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,cancel_meta,cancel_sync;
    reg ack_toggle;
    (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync;
    reg [3:0] pixel_result;
    reg [31:0] produced;
    always @(posedge core_clk or negedge rst_n)
        if(!rst_n) begin ack_meta<=0;ack_sync<=0;end
        else begin ack_meta<=ack_toggle;ack_sync<=ack_meta;end
    always @(posedge pixel_clk or negedge pixel_reset_n)
        if(!pixel_reset_n) begin req_meta<=0;req_sync<=0;cancel_meta<=0;cancel_sync<=0;end
        else begin
            req_meta<=request_toggle;req_sync<=req_meta;
            cancel_meta<=cancel;cancel_sync<=cancel_meta;
        end

    reg [1:0] pixel_state, pack_lane;
    reg previous_vs, previous_de;
    reg [15:0] px, py;
    reg [127:0] pack_word;
    wire frame_edge=(pixel_vs==vs_active) && (previous_vs!=vs_active);
    wire fifo_full,fifo_empty;
    wire [FIFO_ADDR_BITS:0] fifo_level;
    wire [127:0] fifo_data;
    wire pixel_accept=pixel_state==P_FRAME && !cancel_sync && !frame_edge && pixel_de &&
                      px<width && py<height;
    wire push_word=pixel_accept && (pack_lane==3 || px==width-1'b1);
    reg [127:0] packed_pixel;
    always @* begin
        packed_pixel=pack_word;
        // DDR 每像素四字节依次为 R、G、B、0；行尾不足四像素时其余位置补零。
        packed_pixel[pack_lane*32+:32]={8'd0,pixel_rgb[7:0],pixel_rgb[15:8],pixel_rgb[23:16]};
    end
    wire fifo_pop;
    video_async_fifo #(.WIDTH(128),.ADDR_BITS(FIFO_ADDR_BITS)) u_fifo (
        .wr_clk(pixel_clk),.wr_reset_n(pixel_reset_n),.wr_en(push_word),.wr_data(packed_pixel),.full(fifo_full),
        .rd_clk(core_clk),.rd_reset_n(rst_n),.rd_en(fifo_pop),.rd_data(fifo_data),
        .empty(fifo_empty),.rd_level(fifo_level)
    );
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if(!pixel_reset_n) begin
            pixel_state<=P_IDLE;pack_lane<=0;pack_word<=0;px<=0;py<=0;produced<=0;
            previous_vs<=0;previous_de<=0;ack_toggle<=0;pixel_result<=0;
        end else begin
            previous_vs<=pixel_vs;previous_de<=pixel_de;
            if(cancel_sync) begin pixel_state<=P_IDLE;end
            else case(pixel_state)
                P_IDLE: if(req_sync!=ack_toggle) begin
                    pixel_state<=P_WAIT;pack_lane<=0;pack_word<=0;px<=0;py<=0;produced<=0;pixel_result<=0;
                end
                P_WAIT: if(frame_edge) pixel_state<=P_FRAME;
                P_FRAME: begin
                    // 在下一次帧同步时核对总行数，防止少行或多行仍被报告为成功。
                    if(frame_edge) begin
                        pixel_result<=(py==height && px==0 && !pixel_de)?4'd0:E_FRAME;
                        ack_toggle<=req_sync;pixel_state<=P_IDLE;
                    end else if(pixel_de) begin
                        if(px>=width || py>=height) begin
                            pixel_result<=E_FRAME;ack_toggle<=req_sync;pixel_state<=P_IDLE;
                        end else if(push_word && fifo_full) begin
                            pixel_result<=E_OVERFLOW;ack_toggle<=req_sync;pixel_state<=P_IDLE;
                        end else begin
                            px<=px+1'b1;
                            if(push_word) begin produced<=produced+1'b1;pack_word<=0;pack_lane<=0;end
                            else begin pack_word<=packed_pixel;pack_lane<=pack_lane+1'b1;end
                        end
                    end else if(previous_de) begin
                        if(px!=width) begin
                            pixel_result<=E_FRAME;ack_toggle<=req_sync;pixel_state<=P_IDLE;
                        end else begin py<=py+1'b1;px<=0;pack_lane<=0;pack_word<=0;end
                    end
                end
                default: pixel_state<=P_IDLE;
            endcase
        end
    end

    wire result_arrived=!pixel_finished && ack_sync==request_toggle;
    wire timed_out=!pixel_finished && timer>=timeout_limit;
    wire stop_now=timed_out || !ddr_initialized;
    wire [15:0] row_remaining=row_beats-row_cursor;
    wire [4:0] next_chunk=row_remaining>16?5'd16:row_remaining[4:0];
    assign cmd_ready=state==S_IDLE && !fault;
    assign dma_cmd_valid=state==S_SEND && !stop_now;
    assign dma_cmd_addr=row_address+{12'd0,row_cursor,4'd0};
    assign dma_cmd_len={23'd0,chunk_beats,4'd0};
    assign dma_wr_valid=state==S_WRITE && chunk_sent<chunk_beats && !fifo_empty;
    assign dma_wr_data=fifo_data;
    assign fifo_pop=(dma_wr_valid && dma_wr_ready) || (state==S_DROP && !fifo_empty && consumed<produced_limit);

    always @(posedge core_clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_IDLE;done<=0;error<=0;fault<=0;error_code<=0;written_bytes<=0;
            stride<=0;timeout_limit<=0;timer<=0;width<=0;height<=0;vs_active<=1;
            request_toggle<=0;cancel<=0;row<=0;row_beats<=0;row_cursor<=0;
            chunk_beats<=0;chunk_sent<=0;row_address<=0;consumed<=0;
            pixel_finished<=0;aborting<=0;fatal_pending<=0;pending_code<=0;produced_limit<=0;
        end else begin
            if(state!=S_IDLE && state!=S_FAULT) begin
                if(!pixel_finished && !timed_out) timer<=timer+1'b1;
                if(result_arrived) begin
                    pixel_finished<=1;produced_limit<=produced;
                    if(pixel_result!=0) begin aborting<=1;pending_code<=pixel_result;end
                end
                if(stop_now) begin
                    // 时钟/视频停止时无法保证像素域及时应答，锁定到共同复位。
                    // 已提交的 DDR 块仍先排空，绝不在原生写突发中途换所有者。
                    cancel<=1;aborting<=1;fatal_pending<=1;
                    pending_code<=ddr_initialized?E_TIMEOUT:E_DDR;
                end
            end
            if(fifo_pop) consumed<=consumed+1'b1;
            case(state)
                S_IDLE: if(cmd_valid && cmd_ready) begin
                    done<=0;error<=0;error_code<=0;written_bytes<=0;
                    if(cfg_width==0 || cfg_height==0 || cfg_width>4096 || cfg_height>4096 ||
                       cfg_timeout==0 || {32'd0,cfg_stride}<command_row_bytes) begin
                        error<=1;error_code<=E_SHAPE;
                    end else if(cfg_base[3:0]!=0 || cfg_stride[3:0]!=0) begin
                        error<=1;error_code<=E_ALIGN;
                    end else if(command_end>CAPACITY) begin error<=1;error_code<=E_RANGE;end
                    else begin
                        stride<=cfg_stride;timeout_limit<=cfg_timeout;timer<=0;
                        width<=cfg_width;height<=cfg_height;vs_active<=cfg_vs_active;
                        row<=0;row_beats<=command_row_bytes[19:4];row_cursor<=0;
                        row_address<=cfg_base;consumed<=0;pixel_finished<=0;aborting<=0;
                        fatal_pending<=0;pending_code<=0;produced_limit<=0;
                        request_toggle<=!request_toggle;state<=S_WAIT;
                    end
                end
                S_WAIT: begin
                    if(aborting || stop_now) state<=S_DROP;
                    else if(row<height && fifo_level>={{(FIFO_ADDR_BITS-4){1'b0}},next_chunk}) begin
                        // 先确认 FIFO 已有整块，再交给 DMA，防止无 WVALID 的 DDR 口断粮。
                        chunk_beats<=next_chunk;chunk_sent<=0;state<=S_SEND;
                    end else if(pixel_finished && row==height) begin done<=1;state<=S_IDLE;end
                end
                S_SEND: begin
                    if(stop_now) state<=S_DROP;
                    else if(dma_cmd_ready) state<=S_WRITE;
                end
                S_WRITE: begin
                    if(dma_wr_valid && dma_wr_ready) chunk_sent<=chunk_sent+1'b1;
                    if(dma_error) begin
                        cancel<=1;fault<=1;error<=1;error_code<=E_DDR;state<=S_FAULT;
                    end else if(dma_done) begin
                        written_bytes<=written_bytes+{23'd0,chunk_beats,4'd0};
                        if(row_cursor+{11'd0,chunk_beats}==row_beats) begin
                            row<=row+1'b1;row_cursor<=0;row_address<=row_address+stride;
                        end else row_cursor<=row_cursor+{11'd0,chunk_beats};
                        state<=S_WAIT;
                    end
                end
                S_DROP: begin
                    if(fatal_pending || stop_now || dma_fault) begin
                        fault<=1;error<=1;error_code<=pending_code;state<=S_FAULT;
                    end else if(pixel_finished && consumed==produced_limit) begin
                        // 出错帧剩余字全部丢弃后，才允许下一次抓帧，避免混入旧像素。
                        error<=1;error_code<=pending_code;state<=S_IDLE;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
`default_nettype wire
