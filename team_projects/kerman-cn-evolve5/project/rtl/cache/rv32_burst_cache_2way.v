`timescale 1ns/1ps
// Blocking 2-way cache. Data arrays have asynchronous reads in this RTL stage;
// actual FPGA memory mapping/timing is deliberately left for implementation.
// Separate command/response channels; len is beats minus one; ordered responses.
// No posted writes. The downstream memory and this cache share reset.
module rv32_burst_cache_2way #(
    parameter integer ENABLE=1,
    parameter integer BURST_FILL=1,
    parameter integer READ_ONLY=0,
    parameter integer SECOND_READ=0,FAST_STORE=0,
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
    output wire s_second_valid,
    output wire [31:0] s_rdata_second,
    output wire cmd_valid,cmd_write,
    output wire [31:0] cmd_addr,cmd_wdata,
    output wire [3:0] cmd_wstrb,
    output wire [7:0] cmd_len,
    input wire cmd_ready,
    input wire rsp_valid,rsp_error,rsp_last,
    input wire [31:0] rsp_data,
    output wire rsp_ready,
    output wire [31:0] read_hits,read_misses,write_hits,write_misses,
    output wire [31:0] bypass_requests,refill_words,refill_errors
);
    generate if(!ENABLE) begin: disabled
        assign s_second_valid=1'b0;assign s_rdata_second=32'b0;
        rv32_word_to_burst bypass (
            .clk(clk),.rst(rst),.s_valid(s_valid),.s_write(s_write),.s_addr(s_addr),.s_wdata(s_wdata),.s_wstrb(s_wstrb),
            .s_ready(s_ready),.s_error(s_error),.s_rdata(s_rdata),
            .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_wdata(cmd_wdata),.cmd_wstrb(cmd_wstrb),.cmd_len(cmd_len),
            .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),.rsp_last(rsp_last));
        assign read_hits=0; assign read_misses=0; assign write_hits=0; assign write_misses=0;
        assign bypass_requests=0; assign refill_words=0; assign refill_errors=0;
    end else begin: enabled
        localparam integer SETS=1<<SET_BITS, WORDS=1<<LINE_WORD_BITS;
        localparam integer OFFSET_BITS=LINE_WORD_BITS+2;
        localparam integer TAG_BITS=32-SET_BITS-OFFSET_BITS;
        localparam [2:0] IDLE=0,FILL_CMD=1,FILL_R=2,SINGLE_CMD=3,SINGLE_R=4,RESPONSE=5;
        reg [2:0] state;
        reg [SETS-1:0] valid0,valid1,lru;
        reg [TAG_BITS-1:0] tag0[0:SETS-1],tag1[0:SETS-1];
        wire [31:0] way0_data,way1_data;
        wire [31:0] way0_second,way1_second;
        wire [SET_BITS-1:0] req_set=s_addr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
        wire [TAG_BITS-1:0] req_tag=s_addr[31:OFFSET_BITS+SET_BITS];
        wire [LINE_WORD_BITS-1:0] req_word=s_addr[OFFSET_BITS-1:2];
        wire [SET_BITS+LINE_WORD_BITS-1:0] req_index={req_set,req_word};
        wire [LINE_WORD_BITS-1:0] next_word=req_word+1'b1;
        wire [SET_BITS+LINE_WORD_BITS-1:0] next_index={req_set,next_word};
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
        reg fill_failed,demand_failed;
        // One write address/data port per byte bank. Mixing full-word and
        // variable-byte assignments in the control FSM prevents PDS RAM inference.
        wire fill_write=!rst && state==FILL_R && rsp_valid && !rsp_error;
        wire hit_write=!rst && state==SINGLE_R && rsp_valid && s_valid && saved_write && saved_hit && !rsp_error && rsp_last;
        wire array_write=fill_write || hit_write;
        wire [SET_BITS+LINE_WORD_BITS-1:0] write_index=fill_write?fill_index:saved_index;
        wire [31:0] write_value=fill_write?rsp_data:saved_wdata;
        wire [3:0] write_mask=fill_write?4'hf:saved_wstrb;
        genvar byte_lane;
        for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1) begin: bytes
            reg [7:0] bank0[0:SETS*WORDS-1],bank1[0:SETS*WORDS-1];
            assign way0_data[8*byte_lane+:8]=bank0[req_index];
            assign way1_data[8*byte_lane+:8]=bank1[req_index];
            always @(posedge clk) begin
                if(array_write && !saved_way && write_mask[byte_lane]) bank0[write_index]<=write_value[8*byte_lane+:8];
                if(array_write && saved_way && write_mask[byte_lane]) bank1[write_index]<=write_value[8*byte_lane+:8];
            end
        end
        assign read_hits=rh; assign read_misses=rm; assign write_hits=wh; assign write_misses=wm;
        if(SECOND_READ && READ_ONLY) begin: second_port
            genvar lane;
            for(lane=0;lane<4;lane=lane+1) begin: bytes
                // Replicated read bank, identical refill writes, no extra bus transaction.
                reg [7:0] bank0[0:SETS*WORDS-1],bank1[0:SETS*WORDS-1];
                assign way0_second[8*lane+:8]=bank0[next_index];
                assign way1_second[8*lane+:8]=bank1[next_index];
                always @(posedge clk) begin
                    if(array_write && !saved_way && write_mask[lane]) bank0[write_index]<=write_value[8*lane+:8];
                    if(array_write && saved_way && write_mask[lane]) bank1[write_index]<=write_value[8*lane+:8];
                end
            end
        end else begin: no_second_port
            assign way0_second=32'b0;assign way1_second=32'b0;
        end
        assign s_second_valid=SECOND_READ && READ_ONLY && !rst && s_valid && !s_write && state==IDLE && hit && req_word!=WORDS-1;
        assign s_rdata_second=hit0?way0_second:way1_second;
        assign bypass_requests=bp; assign refill_words=fw; assign refill_errors=fe;
        assign s_ready=!rst && s_valid && ((state==IDLE && !s_write && hit) ||
                       (state==SINGLE_R && rsp_valid) || state==RESPONSE);
        assign s_error=s_ready && ((state==SINGLE_R && (rsp_error || !rsp_last)) || (state==RESPONSE && response_error));
        assign s_rdata=state==RESPONSE ? response_data : state==SINGLE_R ? rsp_data : hit0 ? way0_data : way1_data;
        wire direct_store=FAST_STORE && !READ_ONLY && state==IDLE && s_valid && s_write;
        assign cmd_valid=!rst && (state==FILL_CMD || state==SINGLE_CMD || direct_store);
        assign cmd_write=direct_store || (state==SINGLE_CMD && saved_write);
        assign cmd_addr=direct_store?s_addr:state==FILL_CMD ? saved_base+(BURST_FILL?0:fill_word*4) : saved_addr;
        assign cmd_len=state==FILL_CMD && BURST_FILL ? WORDS-1 : 0;
        assign cmd_wdata=direct_store?s_wdata:saved_wdata; assign cmd_wstrb=direct_store?s_wstrb:state==SINGLE_CMD ? saved_wstrb : 4'b0;
        assign rsp_ready=!rst && (state==FILL_R || (state==SINGLE_R && s_valid));
        always @(posedge clk) begin
            if(rst) begin
                state<=IDLE; valid0<=0; valid1<=0; lru<=0;
                saved_addr<=0; saved_wdata<=0; saved_wstrb<=0; saved_base<=0;
                saved_write<=0; saved_hit<=0; saved_way<=0; saved_set<=0;
                saved_tag<=0; saved_word<=0; fill_word<=0; response_data<=0; response_error<=0;
                rh<=0; rm<=0; wh<=0; wm<=0; bp<=0; fw<=0; fe<=0; fill_failed<=0; demand_failed<=0;
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
                            rm<=rm+1; state<=FILL_CMD; fill_word<=0; fill_failed<=0; demand_failed<=0; saved_way<=victim;
                            // Never publish a partially refilled line, including
                            // while reusing an old valid victim.
                            if(victim) valid1[req_set]<=0; else valid0[req_set]<=0;
                        end else begin
                            state<=(direct_store && cmd_ready)?SINGLE_R:SINGLE_CMD;
                            if(cacheable) begin if(hit) wh<=wh+1; else wm<=wm+1; end
                            else bp<=bp+1;
                        end
                    end
                end
                FILL_CMD: if(cmd_ready) state<=FILL_R;
                SINGLE_CMD: if(cmd_ready) state<=SINGLE_R;
                FILL_R: if(rsp_valid) begin
                    // The backend returns exactly cmd_len+1 ordered responses.
                    // All beats are drained even after an access error.
                    if(rsp_error) begin
                        fe<=fe+1; fill_failed<=1;
                        if(fill_word==saved_word) demand_failed<=1;
                    end else begin
                        fw<=fw+1;
                        if(fill_word==saved_word) response_data<=rsp_data;
                    end
                    if(fill_word==WORDS-1) begin
                        if(demand_failed || (rsp_error && fill_word==saved_word)) begin
                            response_error<=1; response_data<=0; state<=RESPONSE;
                        end else if(fill_failed || rsp_error) begin
                            // Only a neighbouring word failed: retry the demand
                            // as one word, without publishing the partial line.
                            state<=SINGLE_CMD; saved_hit<=0;
                        end else begin
                            if(saved_way) begin valid1[saved_set]<=1; tag1[saved_set]<=saved_tag; end
                            else begin valid0[saved_set]<=1; tag0[saved_set]<=saved_tag; end
                            lru[saved_set]<=!saved_way; response_error<=0; state<=RESPONSE;
                        end
                    end else begin fill_word<=fill_word+1'b1; if(!BURST_FILL) state<=FILL_CMD; end
                end
                SINGLE_R: if(rsp_valid && s_valid) begin
                    // Never acknowledge the CPU before receiving the backend
                    // response. RAM writes occur on the accepted response in
                    // this backend; MMIO may commit earlier, exactly once.
                    if(saved_write && saved_hit) begin
                        if(rsp_error || !rsp_last) begin
                            if(saved_way) valid1[saved_set]<=0; else valid0[saved_set]<=0;
                        end else begin
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
