`timescale 1ns/1ps
// Blocking 2-way cache. Data arrays have asynchronous reads in this RTL stage;
// actual FPGA memory mapping/timing is deliberately left for implementation.
// Backend contract: one scalar transaction completes on valid && ready.
// No posted writes. The downstream memory and this cache share reset.
module rv32_cache_2way #(
    parameter integer ENABLE=1,
    parameter integer READ_ONLY=0,
    parameter integer SET_BITS=5,
    parameter integer LINE_WORD_BITS=2,
    parameter integer ROM_BYTES=32768,
    parameter [31:0] RAM_BASE=32'h20000000,
    parameter integer RAM_BYTES=32768
)(
    input wire clk,rst,
    input wire s_valid,s_write,
    input wire [31:0] s_addr,s_wdata,
    input wire [3:0] s_wstrb,
    output wire s_ready,s_error,
    output wire [31:0] s_rdata,
    output wire m_valid,m_write,
    output wire [31:0] m_addr,m_wdata,
    output wire [3:0] m_wstrb,
    input wire m_ready,m_error,
    input wire [31:0] m_rdata,
    output wire [31:0] read_hits,read_misses,write_hits,write_misses,
    output wire [31:0] bypass_requests,refill_words,refill_errors
);
    generate if(!ENABLE) begin: disabled
        assign m_valid=s_valid && !rst;
        assign m_write=s_write; assign m_addr=s_addr;
        assign m_wdata=s_wdata; assign m_wstrb=s_wstrb;
        assign s_ready=s_valid && !rst && m_ready;
        assign s_error=s_ready && m_error; assign s_rdata=m_rdata;
        assign read_hits=0; assign read_misses=0; assign write_hits=0; assign write_misses=0;
        assign bypass_requests=0; assign refill_words=0; assign refill_errors=0;
    end else begin: enabled
        localparam integer SETS=1<<SET_BITS, WORDS=1<<LINE_WORD_BITS;
        localparam integer OFFSET_BITS=LINE_WORD_BITS+2;
        localparam integer TAG_BITS=32-SET_BITS-OFFSET_BITS;
        localparam [2:0] IDLE=0,FILL=1,FORWARD=2,RESPONSE=3;
        reg [2:0] state;
        reg [SETS-1:0] valid0,valid1,lru;
        reg [TAG_BITS-1:0] tag0[0:SETS-1],tag1[0:SETS-1];
        reg [31:0] data0[0:SETS*WORDS-1],data1[0:SETS*WORDS-1];
        wire [SET_BITS-1:0] req_set=s_addr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
        wire [TAG_BITS-1:0] req_tag=s_addr[31:OFFSET_BITS+SET_BITS];
        wire [LINE_WORD_BITS-1:0] req_word=s_addr[OFFSET_BITS-1:2];
        wire [SET_BITS+LINE_WORD_BITS-1:0] req_index={req_set,req_word};
        wire [31:0] req_base={s_addr[31:OFFSET_BITS],{OFFSET_BITS{1'b0}}};
        wire [32:0] line_limit={1'b0,req_base}+(WORDS*4);
        wire in_rom=s_addr<ROM_BYTES && line_limit<=ROM_BYTES;
        wire in_ram=s_addr>=RAM_BASE && req_base>=RAM_BASE &&
                    {1'b0,s_addr}<({1'b0,RAM_BASE}+RAM_BYTES) &&
                    line_limit<=({1'b0,RAM_BASE}+RAM_BYTES);
        // Full line must stay in one cacheable region. RAM is non-executable;
        // ROM writes and all MMIO/unmapped requests go to the original decoder.
        wire cacheable=READ_ONLY ? (!s_write && s_addr[1:0]==0 && in_rom) :
                                  (s_write ? in_ram : (in_rom || in_ram));
        wire hit0=valid0[req_set] && tag0[req_set]==req_tag;
        wire hit1=valid1[req_set] && tag1[req_set]==req_tag;
        wire hit=cacheable && (hit0 || hit1);
        wire victim=!valid0[req_set] ? 1'b0 : !valid1[req_set] ? 1'b1 : lru[req_set];
        reg [31:0] saved_addr,saved_wdata,saved_base,response_data;
        reg [3:0] saved_wstrb;
        reg saved_write,saved_hit,saved_way,response_error;
        reg [SET_BITS-1:0] saved_set;
        reg [TAG_BITS-1:0] saved_tag;
        reg [LINE_WORD_BITS-1:0] saved_word,fill_word;
        wire [SET_BITS+LINE_WORD_BITS-1:0] fill_index={saved_set,fill_word};
        wire [SET_BITS+LINE_WORD_BITS-1:0] saved_index={saved_set,saved_word};
        reg [31:0] rh,rm,wh,wm,bp,fw,fe;
        integer lane;
        assign read_hits=rh; assign read_misses=rm; assign write_hits=wh; assign write_misses=wm;
        assign bypass_requests=bp; assign refill_words=fw; assign refill_errors=fe;
        assign s_ready=!rst && s_valid && ((state==IDLE && !s_write && hit) ||
                       (state==FORWARD && m_ready) || state==RESPONSE);
        assign s_error=s_ready && ((state==FORWARD && m_error) || (state==RESPONSE && response_error));
        assign s_rdata=state==RESPONSE ? response_data : state==FORWARD ? m_rdata :
                       hit0 ? data0[req_index] : data1[req_index];
        assign m_valid=!rst && (state==FILL || state==FORWARD);
        assign m_write=state==FORWARD && saved_write;
        assign m_addr=state==FILL ? saved_base+(fill_word*4) : saved_addr;
        assign m_wdata=saved_wdata;
        assign m_wstrb=state==FORWARD ? saved_wstrb : 4'b0;
        always @(posedge clk) begin
            if(rst) begin
                state<=IDLE; valid0<=0; valid1<=0; lru<=0;
                saved_addr<=0; saved_wdata<=0; saved_wstrb<=0; saved_base<=0;
                saved_write<=0; saved_hit<=0; saved_way<=0; saved_set<=0;
                saved_tag<=0; saved_word<=0; fill_word<=0; response_data<=0; response_error<=0;
                rh<=0; rm<=0; wh<=0; wm<=0; bp<=0; fw<=0; fe<=0;
            end else case(state)
                IDLE: if(s_valid) begin
                    if(!s_write && hit) begin
                        rh<=rh+1; lru[req_set]<=!hit1;
                    end else begin
                        saved_addr<=s_addr; saved_wdata<=s_wdata; saved_wstrb<=s_wstrb;
                        saved_write<=s_write; saved_set<=req_set; saved_tag<=req_tag;
                        saved_word<=req_word; saved_base<=req_base;
                        saved_hit<=hit; saved_way<=hit1; response_error<=0;
                        if(!s_write && cacheable) begin
                            rm<=rm+1; state<=FILL; fill_word<=0; saved_way<=victim;
                            // Never publish a partially refilled line, including
                            // while reusing an old valid victim.
                            if(victim) valid1[req_set]<=0; else valid0[req_set]<=0;
                        end else begin
                            state<=FORWARD;
                            if(cacheable) begin if(hit) wh<=wh+1; else wm<=wm+1; end
                            else bp<=bp+1;
                        end
                    end
                end
                FILL: if(m_ready) begin
                    if(m_error) begin
                        fe<=fe+1;
                        if(fill_word==saved_word) begin
                            response_error<=1; response_data<=0; state<=RESPONSE;
                        end else begin
                            // A failed speculative neighbouring word must not
                            // fault a valid demand access. Retry only its address;
                            // leave the incomplete line invalid.
                            state<=FORWARD; saved_hit<=0;
                        end
                    end else begin
                        fw<=fw+1;
                        if(saved_way) data1[fill_index]<=m_rdata; else data0[fill_index]<=m_rdata;
                        if(fill_word==saved_word) response_data<=m_rdata;
                        if(fill_word==WORDS-1) begin
                            if(saved_way) begin valid1[saved_set]<=1; tag1[saved_set]<=saved_tag; end
                            else begin valid0[saved_set]<=1; tag0[saved_set]<=saved_tag; end
                            lru[saved_set]<=!saved_way; response_error<=0; state<=RESPONSE;
                        end else fill_word<=fill_word+1'b1;
                    end
                end
                FORWARD: if(m_ready) begin
                    // Backend store and CPU completion occur at the same edge.
                    // WT hits update only after successful completion; misses
                    // never allocate. Failed writes invalidate any matching line.
                    if(saved_write && saved_hit) begin
                        if(m_error) begin
                            if(saved_way) valid1[saved_set]<=0; else valid0[saved_set]<=0;
                        end else begin
                            for(lane=0;lane<4;lane=lane+1) if(saved_wstrb[lane]) begin
                                if(saved_way) data1[saved_index][8*lane+:8]<=saved_wdata[8*lane+:8];
                                else data0[saved_index][8*lane+:8]<=saved_wdata[8*lane+:8];
                            end
                            lru[saved_set]<=!saved_way;
                        end
                    end
                    state<=IDLE;
                end
                RESPONSE: if(s_valid) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end endgenerate
endmodule
