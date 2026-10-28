`ifndef RV32_DEFS_VH
`define RV32_DEFS_VH
`define ALU_ADD  4'd0
`define ALU_SUB  4'd1
`define ALU_SLL  4'd2
`define ALU_SLT  4'd3
`define ALU_SLTU 4'd4
`define ALU_XOR  4'd5
`define ALU_SRL  4'd6
`define ALU_SRA  4'd7
`define ALU_OR   4'd8
`define ALU_AND  4'd9
`define ALU_COPY 4'd10
`endif

`timescale 1ns/1ps
// Two masters, one in-flight command. Grant is locked through the last response.
// A command stalled before acceptance also retains its original grant.
module rv32_burst_arbiter (
    input wire clk,rst,
    input wire i_valid,i_write,
    input wire [31:0] i_addr,i_wdata,
    input wire [3:0] i_wstrb,
    input wire [7:0] i_len,
    output wire i_ready,i_rsp_valid,i_rsp_error,i_rsp_last,
    output wire [31:0] i_rsp_data,
    input wire i_rsp_ready,
    input wire d_valid,d_write,
    input wire [31:0] d_addr,d_wdata,
    input wire [3:0] d_wstrb,
    input wire [7:0] d_len,
    output wire d_ready,d_rsp_valid,d_rsp_error,d_rsp_last,
    output wire [31:0] d_rsp_data,
    input wire d_rsp_ready,
    output wire cmd_valid,cmd_write,cmd_instr,
    output wire [31:0] cmd_addr,cmd_wdata,
    output wire [3:0] cmd_wstrb,
    output wire [7:0] cmd_len,
    input wire cmd_ready,
    input wire rsp_valid,rsp_error,rsp_last,
    input wire [31:0] rsp_data,
    output wire rsp_ready
);
    localparam IDLE=0,HOLD=1,ACTIVE=2;
    reg [1:0] state;
    reg owner,prefer_d;
    wire grant=state==HOLD ? owner : (d_valid && (!i_valid || prefer_d));
    assign cmd_valid=!rst && state!=ACTIVE && (grant ? d_valid : i_valid);
    assign cmd_write=grant?d_write:i_write; assign cmd_instr=!grant;
    assign cmd_addr=grant?d_addr:i_addr; assign cmd_wdata=grant?d_wdata:i_wdata;
    assign cmd_wstrb=grant?d_wstrb:i_wstrb; assign cmd_len=grant?d_len:i_len;
    assign i_ready=cmd_valid && !grant && cmd_ready;
    assign d_ready=cmd_valid && grant && cmd_ready;
    assign i_rsp_valid=!rst && state==ACTIVE && !owner && rsp_valid;
    assign d_rsp_valid=!rst && state==ACTIVE && owner && rsp_valid;
    assign i_rsp_data=rsp_data; assign d_rsp_data=rsp_data;
    assign i_rsp_error=rsp_error; assign d_rsp_error=rsp_error;
    assign i_rsp_last=rsp_last; assign d_rsp_last=rsp_last;
    assign rsp_ready=!rst && state==ACTIVE && (owner?d_rsp_ready:i_rsp_ready);
    always @(posedge clk) begin
        if(rst) begin state<=IDLE; owner<=0; prefer_d<=0; end
        else if(state!=ACTIVE && cmd_valid) begin owner<=grant; state<=cmd_ready?ACTIVE:HOLD; end
        else if(state==ACTIVE && rsp_valid && rsp_ready && rsp_last) begin state<=IDLE; prefer_d<=!owner; end
    end
endmodule

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
        integer tag_index;
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
                for(tag_index=0;tag_index<SETS;tag_index=tag_index+1) begin
                    tag0[tag_index]<=0;
                    tag1[tag_index]<=0;
                end
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

`timescale 1ns/1ps
module rv32_dcache #(
    parameter integer BURST_INTERFACE=0,BURST_FILL=1,FAST_STORE=0,
    parameter integer ENABLE=1,SET_BITS=5,LINE_WORD_BITS=2,ROM_BYTES=32768,RAM_BYTES=32768,
    parameter [31:0] RAM_BASE=32'h20000000
)(
    input wire clk,rst,valid,write,
    input wire [31:0] addr,wdata,
    input wire [3:0] wstrb,
    output wire ready,error,
    output wire [31:0] rdata,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,mem_wdata,
    output wire [3:0] mem_wstrb,
    input wire mem_ready,mem_error,
    input wire [31:0] mem_rdata,
    output wire cmd_valid,cmd_write,
    output wire [31:0] cmd_addr,cmd_wdata,
    output wire [3:0] cmd_wstrb,
    output wire [7:0] cmd_len,
    input wire cmd_ready,
    input wire rsp_valid,rsp_error,rsp_last,
    input wire [31:0] rsp_data,
    output wire rsp_ready,
    output wire [31:0] read_hits,read_misses,write_hits,write_misses,bypass_requests,refill_words,refill_errors
);
    generate if(BURST_INTERFACE) begin: burst
    assign mem_valid=0; assign mem_addr=0; assign mem_write=0; assign mem_wdata=0; assign mem_wstrb=0;
    rv32_burst_cache_2way #(.ENABLE(ENABLE),.BURST_FILL(BURST_FILL),.READ_ONLY(0),.FAST_STORE(FAST_STORE),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES),.RAM_BASE(RAM_BASE),.RAM_BYTES(RAM_BYTES)) cache (
        .clk(clk),.rst(rst),.s_valid(valid),.s_write(write),.s_addr(addr),.s_wdata(wdata),.s_wstrb(wstrb),
        .s_second_valid(),.s_rdata_second(),
        .s_ready(ready),.s_error(error),.s_rdata(rdata),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_wdata(cmd_wdata),.cmd_wstrb(cmd_wstrb),.cmd_len(cmd_len),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),.rsp_last(rsp_last),.read_hits(read_hits),.read_misses(read_misses),
        .write_hits(write_hits),.write_misses(write_misses),.bypass_requests(bypass_requests),.refill_words(refill_words),.refill_errors(refill_errors));
    end else begin: scalar
    assign cmd_valid=0; assign cmd_write=0; assign cmd_addr=0; assign cmd_wdata=0; assign cmd_wstrb=0; assign cmd_len=0; assign rsp_ready=0;
    rv32_cache_2way #(.ENABLE(ENABLE),.READ_ONLY(0),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES),.RAM_BASE(RAM_BASE),.RAM_BYTES(RAM_BYTES)) cache (
        .clk(clk),.rst(rst),.s_valid(valid),.s_write(write),.s_addr(addr),.s_wdata(wdata),.s_wstrb(wstrb),
        .s_ready(ready),.s_error(error),.s_rdata(rdata),.m_valid(mem_valid),.m_addr(mem_addr),.m_write(mem_write),.m_wdata(mem_wdata),.m_wstrb(mem_wstrb),
        .m_ready(mem_ready),.m_error(mem_error),.m_rdata(mem_rdata),.read_hits(read_hits),.read_misses(read_misses),
        .write_hits(write_hits),.write_misses(write_misses),.bypass_requests(bypass_requests),.refill_words(refill_words),.refill_errors(refill_errors));
    end endgenerate
endmodule

`timescale 1ns/1ps
module rv32_icache #(
    parameter integer BURST_INTERFACE=0,BURST_FILL=1,WIDE_FETCH=0,
    parameter integer ENABLE=1,SET_BITS=5,LINE_WORD_BITS=2,ROM_BYTES=32768
)(
    input wire clk,rst,valid,
    input wire [31:0] addr,
    output wire ready,error,
    output wire [31:0] rdata,
    output wire second_valid,
    output wire [31:0] rdata_second,
    output wire mem_valid,
    output wire [31:0] mem_addr,
    input wire mem_ready,mem_error,
    input wire [31:0] mem_rdata,
    output wire cmd_valid,cmd_write,
    output wire [31:0] cmd_addr,cmd_wdata,
    output wire [3:0] cmd_wstrb,
    output wire [7:0] cmd_len,
    input wire cmd_ready,
    input wire rsp_valid,rsp_error,rsp_last,
    input wire [31:0] rsp_data,
    output wire rsp_ready,
    output wire [31:0] read_hits,read_misses,refill_words,refill_errors
);
    generate if(BURST_INTERFACE) begin: burst
    assign mem_valid=0; assign mem_addr=0;
    rv32_burst_cache_2way #(.ENABLE(ENABLE),.BURST_FILL(BURST_FILL),.READ_ONLY(1),.SECOND_READ(WIDE_FETCH),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES),.RAM_BYTES(0)) cache (
        .clk(clk),.rst(rst),.s_valid(valid),.s_write(1'b0),.s_addr(addr),.s_wdata(32'b0),.s_wstrb(4'b0),
        .s_ready(ready),.s_error(error),.s_rdata(rdata),.s_second_valid(second_valid),.s_rdata_second(rdata_second),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_wdata(cmd_wdata),.cmd_wstrb(cmd_wstrb),.cmd_len(cmd_len),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),.rsp_last(rsp_last),.read_hits(read_hits),.read_misses(read_misses),
        .write_hits(),.write_misses(),.bypass_requests(),.refill_words(refill_words),.refill_errors(refill_errors));
    end else begin: scalar
    assign second_valid=1'b0;assign rdata_second=32'b0;
    assign cmd_valid=0; assign cmd_write=0; assign cmd_addr=0; assign cmd_wdata=0; assign cmd_wstrb=0; assign cmd_len=0; assign rsp_ready=0;
    rv32_cache_2way #(.ENABLE(ENABLE),.READ_ONLY(1),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES),.RAM_BYTES(0)) cache (
        .clk(clk),.rst(rst),.s_valid(valid),.s_write(1'b0),.s_addr(addr),.s_wdata(32'b0),.s_wstrb(4'b0),
        .s_ready(ready),.s_error(error),.s_rdata(rdata),.m_valid(mem_valid),.m_addr(mem_addr),.m_write(),.m_wdata(),.m_wstrb(),
        .m_ready(mem_ready),.m_error(mem_error),.m_rdata(mem_rdata),.read_hits(read_hits),.read_misses(read_misses),
        .write_hits(),.write_misses(),.bypass_requests(),.refill_words(refill_words),.refill_errors(refill_errors));
    end endgenerate
endmodule

`timescale 1ns/1ps
// One CPU completion-handshake request -> one command and one response.
module rv32_word_to_burst (
    input wire clk,rst,s_valid,s_write,
    input wire [31:0] s_addr,s_wdata,
    input wire [3:0] s_wstrb,
    output wire s_ready,s_error,
    output wire [31:0] s_rdata,
    output wire cmd_valid,cmd_write,
    input wire cmd_ready,
    output wire [31:0] cmd_addr,cmd_wdata,
    output wire [3:0] cmd_wstrb,
    output wire [7:0] cmd_len,
    input wire rsp_valid,rsp_error,rsp_last,
    input wire [31:0] rsp_data,
    output wire rsp_ready
);
    reg active;
    assign cmd_valid=!rst && s_valid && !active;
    assign cmd_write=s_write; assign cmd_addr=s_addr; assign cmd_wdata=s_wdata; assign cmd_wstrb=s_wstrb; assign cmd_len=0;
    assign rsp_ready=!rst && active && s_valid;
    assign s_ready=rsp_ready && rsp_valid;
    assign s_error=s_ready && (rsp_error || !rsp_last);
    assign s_rdata=rsp_data;
    always @(posedge clk) begin
        if(rst) active<=0;
        else if(cmd_valid && cmd_ready) active<=1;
        else if(s_ready) active<=0;
    end
endmodule

`timescale 1ns/1ps

module rv32_alu (
    input wire [31:0] a, b,
    input wire [3:0] op,
    output reg [31:0] result
);
    always @* begin
        case (op)
            `ALU_ADD:  result = a + b;
            `ALU_SUB:  result = a - b;
            `ALU_SLL:  result = a << b[4:0];
            `ALU_SLT:  result = {31'b0, $signed(a) < $signed(b)};
            `ALU_SLTU: result = {31'b0, a < b};
            `ALU_XOR:  result = a ^ b;
            `ALU_SRL:  result = a >> b[4:0];
            `ALU_SRA:  result = $signed(a) >>> b[4:0];
            `ALU_OR:   result = a | b;
            `ALU_AND:  result = a & b;
            `ALU_COPY: result = b;
            default:  result = 32'b0;
        endcase
    end
endmodule

`timescale 1ns/1ps

// Optional restricted dual-issue, in-order RV32IM core: IF / ID / EX / MEM / WB.
// Bus contract: valid + ready completes exactly ONE transaction at a rising
// edge. The slave returns read data/error with ready. The master holds payload
// stable while waiting. There are no posted stores or combinational RAM claims.
// Machine-only traps: synchronous exceptions commit at WB; timer interrupts
// drain the pipeline before entering the handler. CSR instructions serialize.
// No lower privilege modes, PMP, MMU, or external interrupt controller.
module rv32_core #(
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter [31:0] RESET_MTVEC = 32'h00000000,
    parameter integer M_ENABLE=0, DIV_ENABLE=0,
    parameter integer BP_ENABLE=1,
    parameter integer BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, FETCH_DEPTH=1, FETCH_BYPASS=0, LOAD_FORWARD=0,
    parameter integer DUAL_ENABLE=0, WIDE_FETCH=0, PAIR_BRANCH=0, PAIR_MEMORY=0, PAIR_JALR=0, FAST_MUL=0, FAST_STORE=0, PAIR_MUL=0
) (
    input wire clk, rst,
    input wire irq_timer,
    output wire interrupt_taken,
    output wire imem_valid,
    output wire [31:0] imem_addr,
    input wire imem_ready,
    input wire [31:0] imem_rdata,
    input wire imem_error,
    input wire imem_second_valid,imem_second_error,
    input wire [31:0] imem_rdata_second,
    output wire dmem_valid, dmem_write,
    output wire [31:0] dmem_addr, dmem_wdata,
    output wire [3:0] dmem_wstrb,
    input wire dmem_ready,
    input wire [31:0] dmem_rdata,
    input wire dmem_error,
    output reg halted,
    output reg [31:0] trap_pc, trap_cause, trap_tval,
    output wire retire_valid, retire_trap, retire_rd_we,
    output wire [31:0] retire_pc, retire_insn, retire_next_pc,
    output wire [4:0] retire_rd,
    output wire [31:0] retire_rd_data,
    output wire [31:0] retire_mem_addr, retire_mem_wdata, retire_mem_rdata,
    output wire [3:0] retire_mem_wmask, retire_mem_rmask,
    output wire [31:0] retire_cause, retire_tval,
    output wire [31:0] retire2_mem_addr,retire2_mem_wdata,retire2_mem_rdata,
    output wire [3:0] retire2_mem_wmask,retire2_mem_rmask,
    output wire retire2_valid,retire2_rd_we,
    output wire [31:0] retire2_pc,retire2_insn,retire2_next_pc,retire2_rd_data,
    output wire [4:0] retire2_rd,
    output reg [63:0] cycles, instret,
    output reg [63:0] load_stall_cycles, data_wait_cycles,
    output reg [63:0] fetch_wait_cycles, redirect_count
);
    // ID: the fetch buffer is the IF/ID pipeline register.
    wire id_valid, id_fetch_error, id_ready;
    wire [31:0] id_pc, id_insn;
    wire id2_valid,id2_fetch_error,issue_pair;
    wire [31:0] id2_pc,id2_insn,id2_imm,id2_r1,id2_r2;
    wire [4:0] id2_rs1,id2_rs2,id2_rd;
    wire id2_use1,id2_use2,id2_we,id2_pc_a,id2_imm_b,id2_illegal,id2_branch,id2_jal,id2_jalr,id2_load,id2_store;
    wire [31:0] id2_next_pc;
    wire id2_hit,id2_taken,id2_ras;
    wire [PHT_BITS-1:0] id2_index;
    wire [3:0] id2_alu;
    reg [31:0] issue_pairs,retired_pairs;
    wire [31:0] id_predicted_next_pc;
    wire id_prediction_hit,id_prediction_taken,id_prediction_ras;
    wire [PHT_BITS-1:0] id_prediction_index;
    wire bp_update_valid;
    wire bp_update_conditional,bp_update_taken;
    wire [31:0] bp_update_pc,bp_update_target;
    wire [31:0] bp_update_insn;
    wire [PHT_BITS-1:0] bp_update_index;
    wire [4:0] id_rs1, id_rs2, id_rd;
    wire id_use1, id_use2, id_we, id_pc_a, id_imm_b;
    wire id_load, id_store, id_branch, id_jal, id_jalr;
    wire id_illegal, id_ecall, id_ebreak;
    wire [31:0] id_imm, id_r1, id_r2;
    wire [3:0] id_alu;
    wire [2:0] id_f3;
    wire redirect;
    wire [31:0] redirect_pc;
    wire halting,secondary_exception_pending;
    wire id_csr = id_insn[6:0]==7'h73 && (id_f3==1 || id_f3==2 || id_f3==3 || id_f3==5 || id_f3==6 || id_f3==7);
    wire id_system = id_csr || id_insn==32'h30200073 || id_insn==32'h10500073;
    wire irq_enabled, irq_hold, irq_boundary;
    reg irq_draining;
    reg [31:0] arch_next_pc;
    wire [31:0] csr_read_data, csr_mtvec, csr_mepc;
    wire csr_known, csr_readonly;
    wire [31:0] count_inhibit;
    wire returning;
    wire csr_commit;
    wire [31:0] trap_target;
    rv32_fetch #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(FETCH_DEPTH),.BYPASS(FETCH_BYPASS),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH)) fetch (
        .clk(clk), .rst(rst), .stop(halting || returning || irq_hold || secondary_exception_pending),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .req_valid(imem_valid), .req_addr(imem_addr),
        .rsp_ready(imem_ready), .rsp_data(imem_rdata), .rsp_error(imem_error),
        .rsp_second_valid(imem_second_valid),.rsp_second_error(imem_second_error),.rsp_data_second(imem_rdata_second),
        .buf_second_next_pc(id2_next_pc),.buf_second_hit(id2_hit),.buf_second_taken(id2_taken),.buf_second_ras(id2_ras),.buf_second_index(id2_index),.buf_second_valid(id2_valid),.buf_second_pc(id2_pc),.buf_second_insn(id2_insn),.buf_second_error(id2_fetch_error),.buf_take_second(issue_pair && id_ready),
        .buf_valid(id_valid), .buf_pc(id_pc), .buf_insn(id_insn),
        .buf_error(id_fetch_error), .buf_ready(id_ready),
        .buf_predicted_next_pc(id_predicted_next_pc),.buf_prediction_hit(id_prediction_hit),.buf_prediction_taken(id_prediction_taken),.buf_prediction_ras(id_prediction_ras),.buf_prediction_index(id_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(halting || returning || irq_boundary)
    );
    rv32_decode #(.M_ENABLE(M_ENABLE),.DIV_ENABLE(DIV_ENABLE)) decode (
        .insn(id_insn), .rs1(id_rs1), .rs2(id_rs2), .rd(id_rd),
        .use_rs1(id_use1), .use_rs2(id_use2), .rd_write(id_we),
        .imm(id_imm), .alu_op(id_alu), .a_is_pc(id_pc_a), .b_is_imm(id_imm_b),
        .is_load(id_load), .is_store(id_store), .is_branch(id_branch),
        .is_jal(id_jal), .is_jalr(id_jalr), .funct3(id_f3),
        .illegal(id_illegal), .ecall(id_ecall), .ebreak(id_ebreak)
    );
    rv32_decode #(.M_ENABLE(M_ENABLE),.DIV_ENABLE(DIV_ENABLE)) decode_second (
        .insn(id2_insn),.rs1(id2_rs1),.rs2(id2_rs2),.rd(id2_rd),
        .use_rs1(id2_use1),.use_rs2(id2_use2),.rd_write(id2_we),.imm(id2_imm),.alu_op(id2_alu),
        .a_is_pc(id2_pc_a),.b_is_imm(id2_imm_b),.is_load(id2_load),.is_store(id2_store),.is_branch(id2_branch),.is_jal(id2_jal),.is_jalr(id2_jalr),.funct3(),
        .illegal(id2_illegal),.ecall(),.ebreak());
    wire primary_pair_type=id_insn[6:0]==7'h13 || id_insn[6:0]==7'h33 || id_insn[6:0]==7'h37 ||
                           id_insn[6:0]==7'h17 || id_insn[6:0]==7'h03 || id_insn[6:0]==7'h23;
    wire id_multiply=id_insn[6:0]==7'h33 && id_insn[31:25]==1;
    wire id2_multiply=id2_insn[6:0]==7'h33 && id2_insn[31:25]==1;
    wire secondary_pair_type=id2_insn[6:0]==7'h13 || (id2_insn[6:0]==7'h33 && (!id2_multiply || (PAIR_MUL && !id2_insn[14] && !id_multiply))) || id2_insn[6:0]==7'h37 || id2_insn[6:0]==7'h17 || (PAIR_BRANCH && (id2_branch || id2_jal) && id2_imm[1:0]==0) || (PAIR_JALR && id2_jalr) || (PAIR_MEMORY && (id2_load || id2_store) && !id_load && !id_store);
    wire pair_raw=id_we && id_rd!=0 && ((id2_use1 && id2_rs1==id_rd) || (id2_use2 && id2_rs2==id_rd));
    wire pair_waw=id_we && id2_we && id_rd!=0 && id_rd==id2_rd;
    assign issue_pair=DUAL_ENABLE && id_valid && id2_valid && !id_fetch_error && !id2_fetch_error && !id_illegal && !id2_illegal &&
                      primary_pair_type && secondary_pair_type && id2_pc==id_pc+4 && id_predicted_next_pc==id2_pc && !pair_raw && !pair_waw;
    rv32_regfile #(.DUAL_ENABLE(DUAL_ENABLE)) regfile (
        .clk(clk), .rst(rst), .rs1(id_rs1), .rs2(id_rs2),
        .rdata1(id_r1), .rdata2(id_r2),
        .we(retire_rd_we), .rd(retire_rd), .wdata(retire_rd_data),
        .rs3(id2_rs1),.rs4(id2_rs2),.rdata3(id2_r1),.rdata4(id2_r2),
        .we2(retire2_rd_we),.rd2(retire2_rd),.wdata2(retire2_rd_data)
    );

    // EX: ID/EX pipeline register and forwarded operands.
    reg x_valid, x_use1, x_use2, x_we, x_pc_a, x_imm_b;
    reg x_load, x_store, x_branch, x_jal, x_jalr, x_trap;
    reg [31:0] x_pc, x_insn, x_r1, x_r2, x_imm, x_cause, x_tval;
    reg [4:0] x_rs1, x_rs2, x_rd;
    reg [3:0] x_alu;
    reg [2:0] x_f3;
    reg [31:0] x_predicted_next_pc;
    reg x_prediction_hit,x_prediction_taken,x_prediction_ras;
    reg [PHT_BITS-1:0] x_prediction_index,m_prediction_index,w_prediction_index;
    reg m_prediction_ras,w_prediction_ras;
    reg [31:0] operand1, operand2;
    reg [31:0] load_value;
    reg x2_valid,x2_use1,x2_use2,x2_we,x2_pc_a,x2_imm_b;
    reg [31:0] x2_pc,x2_insn,x2_r1,x2_r2,x2_imm;
    reg [4:0] x2_rs1,x2_rs2,x2_rd;
    reg [3:0] x2_alu;
    reg [31:0] operand21,operand22;
    reg m2_valid,m2_we,w2_valid,w2_we;
    reg [31:0] m2_pc,m2_insn,m2_value,w2_pc,w2_insn,w2_value;
    reg [4:0] m2_rd,w2_rd;
    reg [31:0] x2_predicted,m2_next_pc,w2_next_pc;
    reg m2_load,m2_store,m2_trap,w2_trap;
    reg [31:0] m2_addr,m2_wdata,m2_cause,m2_tval,w2_addr,w2_wdata,w2_rdata,w2_cause,w2_tval;
    reg [3:0] m2_wmask,m2_rmask,w2_wmask,w2_rmask;
    reg [2:0] m2_f3;
    wire x2_load=x2_insn[6:0]==7'h03;
    wire x2_store=x2_insn[6:0]==7'h23;
    wire x2_jalr=x2_insn[6:0]==7'h67;
    wire [31:0] branch_target2=x2_jalr ? ((operand21+x2_imm)&32'hfffffffe) : x2_pc+x2_imm;
    reg x2_hit,x2_taken_pred,x2_ras,m2_hit,m2_pred_taken,m2_taken,m2_wrong,w2_hit,w2_pred_taken,w2_taken,w2_wrong;
    reg [PHT_BITS-1:0] x2_index,m2_index,w2_index;
    reg m2_ras,w2_ras;
    wire x2_branch=x2_insn[6:0]==7'h63;
    wire x2_jal=x2_insn[6:0]==7'h6f;
    reg branch2_condition;
    always @* begin
        case(x2_insn[14:12])
            0:branch2_condition=operand21==operand22;
            1:branch2_condition=operand21!=operand22;
            4:branch2_condition=$signed(operand21)<$signed(operand22);
            5:branch2_condition=$signed(operand21)>=$signed(operand22);
            6:branch2_condition=operand21<operand22;
            7:branch2_condition=operand21>=operand22;
            default:branch2_condition=0;
        endcase
    end
    wire x2_taking=x2_valid && (x2_jal || x2_jalr || (x2_branch && branch2_condition));
    wire [31:0] actual_next2=x2_taking ? branch_target2 : x2_pc+4;
    wire prediction_wrong2=x2_valid && actual_next2!=x2_predicted;
    wire [31:0] alu2_result;
    wire misaligned2=(x2_load || x2_store) && ((x2_insn[13:12]==1 && alu2_result[0]) || (x2_insn[13:12]==2 && |alu2_result[1:0]));
    wire ex2_trap=x2_valid && ((x2_taking && |branch_target2[1:0]) || misaligned2);
    wire [31:0] ex2_cause=(x2_taking && |branch_target2[1:0])?32'd0:x2_store?32'd6:32'd4;
    wire [31:0] ex2_tval=(x2_taking && |branch_target2[1:0])?branch_target2:alu2_result;
    wire [3:0] access_mask2=x2_insn[13:12]==0 ? (4'b0001<<alu2_result[1:0]) : x2_insn[13:12]==1 ? (4'b0011<<alu2_result[1:0]) : 4'b1111;
    wire [31:0] store_value2=x2_insn[13:12]==0 ? ({24'b0,operand22[7:0]}<<(8*alu2_result[1:0])) :
                             x2_insn[13:12]==1 ? ({16'b0,operand22[15:0]}<<(8*alu2_result[1:0])) : operand22;
    rv32_alu alu_second(.a(x2_pc_a?x2_pc:operand21),.b(x2_imm_b?x2_imm:operand22),.op(x2_alu),.result(alu2_result));
    wire [31:0] alu_a = x_pc_a ? x_pc : operand1;
    wire [31:0] alu_b = x_imm_b ? x_imm : operand2;
    wire [31:0] alu_result;
    rv32_alu alu (.a(alu_a), .b(alu_b), .op(x_alu), .result(alu_result));

    // MEM: EX/MEM pipeline register. Requests exist only in this stage.
    reg m_valid, m_we, m_load, m_store, m_trap;
    reg [31:0] m_pc, m_insn, m_next_pc, m_value, m_addr;
    reg [31:0] m_wdata, m_cause, m_tval;
    reg [4:0] m_rd;
    reg [3:0] m_wmask, m_rmask;
    reg [2:0] m_f3;
    reg m_taken,m_prediction_hit,m_prediction_taken,m_prediction_wrong;
    // WB: MEM/WB pipeline register. Architectural register state changes here.
    reg w_valid, w_we, w_trap;
    reg [31:0] w_pc, w_insn, w_next_pc, w_value, w_addr;
    reg [31:0] w_wdata, w_rdata, w_cause, w_tval;
    reg [4:0] w_rd;
    reg [3:0] w_wmask, w_rmask;
    reg w_taken,w_prediction_hit,w_prediction_taken,w_prediction_wrong;
    // Simulation/debug counters. Unconnected outputs are optimized away in the
    // normal board build; these are not advertised as readable hardware CSRs.
    reg [63:0] bp_cf_retired,bp_hits,bp_taken_predictions,bp_mispredictions;
    reg [63:0] bp_conditional_retired,bp_direction_misses;
    wire w_control=w_insn[6:0]==7'h63 || w_insn[6:0]==7'h6f || w_insn[6:0]==7'h67;
    wire w2_control=w2_insn[6:0]==7'h63 || w2_insn[6:0]==7'h6f || w2_insn[6:0]==7'h67;
    wire bp_second=retire2_valid && w2_control;
    wire [31:0] bp_committed_insn=bp_second?w2_insn:w_insn;
    wire bp_committed_hit=bp_second?w2_hit:w_prediction_hit;
    wire bp_committed_pred_taken=bp_second?w2_pred_taken:w_prediction_taken;
    wire bp_committed_taken=bp_second?w2_taken:w_taken;
    wire bp_committed_wrong=bp_second?w2_wrong:w_prediction_wrong;
    assign bp_update_valid=(retire_valid && !retire_trap && w_control) || bp_second;
    assign bp_update_conditional=bp_committed_insn[6:0]==7'h63;
    assign bp_update_taken=bp_committed_taken;
    assign bp_update_pc=bp_second?w2_pc:w_pc;
    assign bp_update_target=bp_second?w2_next_pc:w_next_pc;
    assign bp_update_insn=bp_committed_insn;
    assign bp_update_index=bp_second?w2_index:w_prediction_index;

    assign retire_valid = w_valid && !halted && !rst;
    assign retire2_valid=DUAL_ENABLE && retire_valid && w2_valid && !w_trap && !w2_trap;
    assign retire2_mem_addr=retire2_valid && (|w2_wmask || |w2_rmask)?w2_addr:32'b0;
    assign retire2_mem_wmask=retire2_valid?w2_wmask:4'b0;
    assign retire2_mem_rmask=retire2_valid?w2_rmask:4'b0;
    assign retire2_mem_wdata=retire2_valid && |w2_wmask?w2_wdata:32'b0;
    assign retire2_mem_rdata=retire2_valid && |w2_rmask?w2_rdata:32'b0;
    assign retire2_rd_we=retire2_valid && w2_we && w2_rd!=0;
    assign retire2_pc=w2_pc;
    assign retire2_insn=w2_insn;
    assign retire2_next_pc=w2_next_pc;
    assign retire2_rd=retire2_rd_we?w2_rd:5'b0;
    assign retire2_rd_data=retire2_rd_we?w2_value:32'b0;
    assign retire_trap = retire_valid && w_trap;
    assign retire_rd_we = retire_valid && w_we && !w_trap && w_rd != 0;
    assign retire_pc = w_pc;
    assign retire_insn = w_insn;
    assign retire_next_pc = w_trap ? {csr_mtvec[31:2],2'b00} : w_next_pc;
    assign retire_rd = retire_rd_we ? w_rd : 5'b0;
    assign retire_rd_data = retire_rd_we ? w_value : 32'b0;
    assign retire_mem_addr = (!w_trap && (|w_wmask || |w_rmask)) ? w_addr : 32'b0;
    assign retire_mem_wmask = w_trap ? 4'b0 : w_wmask;
    assign retire_mem_rmask = w_trap ? 4'b0 : w_rmask;
    assign retire_mem_wdata = (!w_trap && |w_wmask) ? w_wdata : 32'b0;
    assign retire_mem_rdata = (!w_trap && |w_rmask) ? w_rdata : 32'b0;
    assign retire_cause = w_trap ? w_cause : 32'b0;
    assign retire_tval = w_trap ? w_tval : 32'b0;
    assign halting = w_valid && w_trap && !rst;
    assign secondary_exception_pending=w_valid && w2_trap && !w_trap && !rst;
    wire x_csr = x_insn[6:0]==7'h73 && (x_f3==1 || x_f3==2 || x_f3==3 || x_f3==5 || x_f3==6 || x_f3==7);
    wire x_mret = x_insn==32'h30200073;
    wire x_system = x_csr || x_mret || x_insn==32'h10500073;
    wire m_system = m_insn[6:0]==7'h73 && !m_trap;
    wire w_csr = w_insn[6:0]==7'h73 && w_insn[14:12]!=0 && w_insn[14:12]!=4;
    wire w_system = w_insn[6:0]==7'h73 && !w_trap;
    wire x_csr_write = x_f3[1:0]==1 || x_rs1!=0;
    wire [31:0] x_csr_operand = x_f3[2] ? {27'b0,x_rs1} : operand1;
    wire [31:0] x_csr_new = x_f3[1:0]==1 ? x_csr_operand :
                           x_f3[1:0]==2 ? csr_read_data | x_csr_operand : csr_read_data & ~x_csr_operand;
    assign csr_commit = w_valid && w_csr && !w_trap && !rst && (w_insn[13:12]==1 || w_insn[19:15]!=0);
    assign returning = w_valid && w_insn==32'h30200073 && !w_trap && !rst;
    assign irq_hold = irq_draining || irq_enabled;
    assign irq_boundary = irq_hold && !x_valid && !m_valid && !w_valid && !rst;
    assign interrupt_taken = irq_boundary && irq_enabled;
    assign trap_target = {csr_mtvec[31:2],2'b00} + ((interrupt_taken && csr_mtvec[1:0]==1) ? 32'd28 : 32'd0);
    wire serial_block = (id_system && (x_valid || m_valid || w_valid)) ||
                        (x_valid && x_system) || (m_valid && m_system) || (w_valid && w_system);
    rv32_csr #(.RESET_MTVEC(RESET_MTVEC),.IMPL_ID(32'h00020000 | (M_ENABLE<<16) | (BP_INDEX_BITS<<8) | (DUAL_ENABLE<<2) | (WIDE_FETCH<<3) | (PAIR_JALR<<1) | (PAIR_BRANCH<<4) | (PAIR_MEMORY<<5) | (FAST_STORE<<6) | (FAST_MUL<<7) | (PAIR_MUL<<13) | BP_ENABLE),.M_ENABLE(M_ENABLE && DIV_ENABLE),
        .UARCH_CONFIG(32'hf1000000 | (BP_INDEX_BITS<<20) | (FETCH_DEPTH<<16) | (RAS_DEPTH<<8) | (PHT_BITS<<4) | (FETCH_BYPASS<<2) | (LOAD_FORWARD<<1) | GSHARE_ENABLE),
        .ISSUE_CONFIG(32'hd1000000 | (DUAL_ENABLE<<0) | (WIDE_FETCH<<1))) csrfile (
        .clk(clk),.rst(rst),.read_address(x_insn[31:20]),.read_data(csr_read_data),
        .known(csr_known),.read_only(csr_readonly),.write_enable(csr_commit),
        .write_address(w_insn[31:20]),.write_data(w_addr),
        .trap_enter(halting || interrupt_taken),.trap_epc(interrupt_taken ? arch_next_pc : w_pc),
        .trap_cause(interrupt_taken ? 32'h80000007 : w_cause),.trap_value(interrupt_taken ? 32'b0 : w_tval),
        .mret(returning),.irq_timer(irq_timer),.irq_enabled(irq_enabled),
        .mtvec(csr_mtvec),.mepc(csr_mepc),.cycle_count(cycles),.retired_count(instret),.count_inhibit(count_inhibit),
        .issued_pair_count(issue_pairs),.retired_pair_count(retired_pairs)
    );

    wire memory_in_second=m2_valid && (m2_load || m2_store);
    wire memory_request=m_load || m_store || (memory_in_second && !m2_trap);
    assign dmem_valid=m_valid && memory_request && !m_trap && !halted && !halting && !secondary_exception_pending && !rst;
    assign dmem_write=memory_in_second?m2_store:m_store;
    assign dmem_addr=memory_in_second?m2_addr:m_addr;
    assign dmem_wdata=memory_in_second?m2_wdata:m_wdata;
    assign dmem_wstrb=memory_in_second?m2_wmask:m_wmask;
    wire m_done=m_valid && (m_trap || !memory_request || dmem_ready);
    wire bus_fault=dmem_valid && dmem_ready && dmem_error;
    wire m_fault=bus_fault && !memory_in_second;
    wire m2_fault=bus_fault && memory_in_second;
    wire m_slot=!m_valid || m_done;
    wire load_available=LOAD_FORWARD && dmem_valid && m_load && dmem_ready && !dmem_error;
    wire load_available2=LOAD_FORWARD && dmem_valid && memory_in_second && m2_load && dmem_ready && !dmem_error;
    wire load_dependency0=x_valid && m_valid && m_load && !m_trap && m_rd!=0 &&
         ((x_use1 && x_rs1==m_rd) || (x_use2 && x_rs2==m_rd) || (x2_valid && ((x2_use1 && x2_rs1==m_rd) || (x2_use2 && x2_rs2==m_rd))));
    wire load_dependency2=x_valid && m_valid && m2_valid && m2_load && !m_trap && !m2_trap && m2_rd!=0 &&
         ((x_use1 && x_rs1==m2_rd) || (x_use2 && x_rs2==m2_rd) || (x2_valid && ((x2_use1 && x2_rs1==m2_rd) || (x2_use2 && x2_rs2==m2_rd))));
    wire load_dependency=load_dependency0 || load_dependency2;
    wire load_hazard=(load_dependency0 && !load_available) || (load_dependency2 && !load_available2);
    // Faulting fetch data is unspecified: it must never wait for an M result.
    wire x_mop=M_ENABLE && !x_trap && x_insn[6:0]==7'h33 && x_insn[31:25]==7'h01;
    wire x2_mop=M_ENABLE && x2_valid && x2_insn[6:0]==7'h33 && x2_insn[31:25]==1;
    wire any_mop=x_mop || x2_mop;
    wire md_ready,md_valid;
    wire [31:0] md_result;
    reg md_issued;
    wire md_kill=halting || returning || irq_boundary || secondary_exception_pending;
    // Pending interrupts must allow the existing EX instruction to finish.
    wire md_request=x_valid && any_mop && !x_trap && !load_hazard && !md_issued && !halted && !md_kill;
    wire x_fire = x_valid && m_slot && !load_hazard && (!any_mop || md_valid) && !halted && !halting && !returning && !secondary_exception_pending;
    generate if(M_ENABLE) begin: m_extension
        rv32_muldiv #(.FAST_MUL(FAST_MUL),.DIV_ENABLE(DIV_ENABLE)) unit(.clk(clk),.rst(rst),.kill(md_kill),.req_valid(md_request),.req_ready(md_ready),
            .req_op(x2_mop?x2_insn[14:12]:x_f3),.req_a(x2_mop?operand21:operand1),.req_b(x2_mop?operand22:operand2),.rsp_valid(md_valid),.rsp_ready(x_fire && any_mop),.result(md_result));
    end else begin: m_disabled
        assign md_ready=1'b0; assign md_valid=1'b0; assign md_result=32'b0;
    end endgenerate
    always @(posedge clk) begin
        if(rst || md_kill || x_fire) md_issued<=0;
        else if(md_request && md_ready) md_issued<=1;
    end
    assign id_ready = (!x_valid || x_fire) && !halting && !returning && !redirect && !serial_block && !irq_hold && !secondary_exception_pending;

    always @* begin
        operand1=x_r1;operand2=x_r2;operand21=x2_r1;operand22=x2_r2;
        if(retire_rd_we) begin
            if(x_use1 && x_rs1==w_rd) operand1=w_value;
            if(x_use2 && x_rs2==w_rd) operand2=w_value;
            if(x2_use1 && x2_rs1==w_rd) operand21=w_value;
            if(x2_use2 && x2_rs2==w_rd) operand22=w_value;
        end
        if(retire2_rd_we) begin
            if(x_use1 && x_rs1==w2_rd) operand1=w2_value;
            if(x_use2 && x_rs2==w2_rd) operand2=w2_value;
            if(x2_use1 && x2_rs1==w2_rd) operand21=w2_value;
            if(x2_use2 && x2_rs2==w2_rd) operand22=w2_value;
        end
        if(m_valid && m_we && (!m_load || load_available) && !m_trap && m_rd!=0) begin
            if(x_use1 && x_rs1==m_rd) operand1=m_load?load_value:m_value;
            if(x_use2 && x_rs2==m_rd) operand2=m_load?load_value:m_value;
            if(x2_use1 && x2_rs1==m_rd) operand21=m_load?load_value:m_value;
            if(x2_use2 && x2_rs2==m_rd) operand22=m_load?load_value:m_value;
        end
        if(m_valid && m2_valid && m2_we && (!m2_load || load_available2) && !m_trap && !m2_trap && m2_rd!=0) begin
            if(x_use1 && x_rs1==m2_rd) operand1=m2_load?load_value:m2_value;
            if(x_use2 && x_rs2==m2_rd) operand2=m2_load?load_value:m2_value;
            if(x2_use1 && x2_rs1==m2_rd) operand21=m2_load?load_value:m2_value;
            if(x2_use2 && x2_rs2==m2_rd) operand22=m2_load?load_value:m2_value;
        end
    end

    reg branch_taken;
    always @* begin
        case (x_f3)
            3'd0: branch_taken = operand1 == operand2;
            3'd1: branch_taken = operand1 != operand2;
            3'd4: branch_taken = $signed(operand1) < $signed(operand2);
            3'd5: branch_taken = $signed(operand1) >= $signed(operand2);
            3'd6: branch_taken = operand1 < operand2;
            3'd7: branch_taken = operand1 >= operand2;
            default: branch_taken = 0;
        endcase
    end
    wire taking_branch = x_jal || x_jalr || (x_branch && branch_taken);
    wire [31:0] branch_target = x_jalr ? ((operand1 + x_imm) & 32'hfffffffe) : x_pc + x_imm;
    wire data_misaligned = (x_load || x_store) &&
                           ((x_f3[1:0] == 1 && alu_result[0]) ||
                            (x_f3[1:0] == 2 && |alu_result[1:0]));
    reg ex_trap;
    reg [31:0] ex_cause, ex_tval;
    always @* begin
        ex_trap = x_trap; ex_cause = x_cause; ex_tval = x_tval;
        if (!x_trap && x_csr && (!csr_known || (x_csr_write && csr_readonly))) begin
            ex_trap = 1; ex_cause = 2; ex_tval = x_insn;
        end else if (!x_trap && taking_branch && |branch_target[1:0]) begin
            ex_trap = 1; ex_cause = 0; ex_tval = branch_target;
        end else if (!x_trap && data_misaligned) begin
            ex_trap = 1; ex_cause = x_store ? 32'd6 : 32'd4; ex_tval = alu_result;
        end
    end
    wire [31:0] actual_next_pc=taking_branch ? branch_target : x_pc+32'd4;
    wire prediction_wrong=actual_next_pc!=x_predicted_next_pc;
    wire prediction_recovery=x_fire && !ex_trap && !x_mret && !ex2_trap && !secondary_exception_pending && (prediction_wrong || prediction_wrong2);
    assign redirect = halting || returning || irq_boundary || prediction_recovery;
    assign redirect_pc = halting ? trap_target : returning ? csr_mepc :
                         irq_boundary ? (irq_enabled ? trap_target : arch_next_pc) : prediction_wrong ? actual_next_pc : actual_next2;

    reg [3:0] access_mask;
    reg [31:0] store_value;
    always @* begin
        case (x_f3[1:0])
            2'd0: begin
                access_mask = 4'b0001 << alu_result[1:0];
                store_value = {24'b0,operand2[7:0]} << (8 * alu_result[1:0]);
            end
            2'd1: begin
                access_mask = 4'b0011 << alu_result[1:0];
                store_value = {16'b0,operand2[15:0]} << (8 * alu_result[1:0]);
            end
            default: begin access_mask = 4'b1111; store_value = operand2; end
        endcase
    end
    wire [31:0] shifted_load = dmem_rdata >> (8 * dmem_addr[1:0]);
    always @* begin
        case (memory_in_second?m2_f3:m_f3)
            3'd0: load_value = {{24{shifted_load[7]}},shifted_load[7:0]};
            3'd1: load_value = {{16{shifted_load[15]}},shifted_load[15:0]};
            3'd2: load_value = shifted_load;
            3'd4: load_value = {24'b0,shifted_load[7:0]};
            3'd5: load_value = {16'b0,shifted_load[15:0]};
            default: load_value = 0;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            halted <= 0; trap_pc <= 0; trap_cause <= 0; trap_tval <= 0;
            x2_valid<=0;x2_use1<=0;x2_use2<=0;x2_we<=0;x2_pc_a<=0;x2_imm_b<=0;
            x2_pc<=0;x2_insn<=0;x2_r1<=0;x2_r2<=0;x2_imm<=0;x2_rs1<=0;x2_rs2<=0;x2_rd<=0;x2_alu<=0;
            m2_valid<=0;m2_we<=0;m2_pc<=0;m2_insn<=0;m2_value<=0;m2_rd<=0;
            w2_valid<=0;w2_we<=0;w2_pc<=0;w2_insn<=0;w2_value<=0;w2_rd<=0;
            issue_pairs<=0;retired_pairs<=0;
            m2_load<=0;m2_store<=0;m2_trap<=0;w2_trap<=0;
            m2_addr<=0;m2_wdata<=0;m2_cause<=0;m2_tval<=0;w2_addr<=0;w2_wdata<=0;w2_rdata<=0;w2_cause<=0;w2_tval<=0;
            m2_wmask<=0;m2_rmask<=0;w2_wmask<=0;w2_rmask<=0;m2_f3<=0;
            x2_predicted<=0;m2_next_pc<=0;w2_next_pc<=0;
            x2_hit<=0;x2_taken_pred<=0;x2_ras<=0;m2_ras<=0;w2_ras<=0;m2_hit<=0;m2_pred_taken<=0;m2_taken<=0;m2_wrong<=0;
            w2_hit<=0;w2_pred_taken<=0;w2_taken<=0;w2_wrong<=0;x2_index<=0;m2_index<=0;w2_index<=0;
            irq_draining <= 0; arch_next_pc <= RESET_PC;
            cycles <= 0; instret <= 0; load_stall_cycles <= 0;
            bp_cf_retired<=0; bp_hits<=0; bp_taken_predictions<=0; bp_mispredictions<=0;
            bp_conditional_retired<=0; bp_direction_misses<=0;
            x_predicted_next_pc<=RESET_PC+4; x_prediction_hit<=0; x_prediction_taken<=0; x_prediction_ras<=0;
            x_prediction_index<=0; m_prediction_index<=0; w_prediction_index<=0; m_prediction_ras<=0; w_prediction_ras<=0;
            m_taken<=0; m_prediction_hit<=0; m_prediction_taken<=0; m_prediction_wrong<=0;
            w_taken<=0; w_prediction_hit<=0; w_prediction_taken<=0; w_prediction_wrong<=0;
            data_wait_cycles <= 0; fetch_wait_cycles <= 0; redirect_count <= 0;
            x_valid <= 0; x_pc <= 0; x_insn <= 0; x_r1 <= 0; x_r2 <= 0;
            x_imm <= 0; x_cause <= 0; x_tval <= 0;
            x_rs1 <= 0; x_rs2 <= 0; x_rd <= 0; x_alu <= 0; x_f3 <= 0;
            x_use1 <= 0; x_use2 <= 0; x_we <= 0; x_pc_a <= 0; x_imm_b <= 0;
            x_load <= 0; x_store <= 0; x_branch <= 0; x_jal <= 0; x_jalr <= 0; x_trap <= 0;
            m_valid <= 0; m_we <= 0; m_load <= 0; m_store <= 0; m_trap <= 0;
            m_pc <= 0; m_insn <= 0; m_next_pc <= 0; m_value <= 0; m_addr <= 0;
            m_wdata <= 0; m_cause <= 0; m_tval <= 0; m_rd <= 0;
            m_wmask <= 0; m_rmask <= 0; m_f3 <= 0;
            w_valid <= 0; w_we <= 0; w_trap <= 0;
            w_pc <= 0; w_insn <= 0; w_next_pc <= 0; w_value <= 0; w_addr <= 0;
            w_wdata <= 0; w_rdata <= 0; w_cause <= 0; w_tval <= 0; w_rd <= 0;
            w_wmask <= 0; w_rmask <= 0;
        end else begin
            if(bp_update_valid) begin
                bp_cf_retired<=bp_cf_retired+1;
                if(bp_committed_hit) bp_hits<=bp_hits+1;
                if(bp_committed_pred_taken) bp_taken_predictions<=bp_taken_predictions+1;
                if(bp_committed_wrong) bp_mispredictions<=bp_mispredictions+1;
                if(bp_committed_insn[6:0]==7'h63) begin
                    bp_conditional_retired<=bp_conditional_retired+1;
                    if(bp_committed_pred_taken!=bp_committed_taken) bp_direction_misses<=bp_direction_misses+1;
                end
            end
            if(id_valid && id_ready && issue_pair) issue_pairs<=issue_pairs+1;
            if(retire2_valid) retired_pairs<=retired_pairs+1;
            if (!count_inhibit[0]) cycles <= cycles + 1;
            if (retire_valid && !retire_trap && !count_inhibit[2]) instret <= instret + 64'd1 + (retire2_valid?64'd1:64'd0);
            // Explicit counter writes override that instruction's implicit increment.
            if (csr_commit) case (w_insn[31:20])
                12'hb00: cycles <= {cycles[63:32],w_addr};
                12'hb80: cycles <= {w_addr,cycles[31:0]};
                12'hb02: instret <= {instret[63:32],w_addr};
                12'hb82: instret <= {w_addr,instret[31:0]};
                default: begin end
            endcase
            if (retire_valid && !retire_trap) arch_next_pc <= retire2_valid ? retire2_next_pc : w_next_pc;
            if (halting || returning || irq_boundary) irq_draining <= 0;
            else if (irq_enabled) irq_draining <= 1;
            if (!halted && load_hazard) load_stall_cycles <= load_stall_cycles + 1;
            if (dmem_valid && !dmem_ready) data_wait_cycles <= data_wait_cycles + 1;
            if (imem_valid && !imem_ready) fetch_wait_cycles <= fetch_wait_cycles + 1;
            if (redirect) redirect_count <= redirect_count + 1;
            if (halting || returning || irq_boundary) begin
                arch_next_pc <= redirect_pc;
                if (halting || interrupt_taken) begin
                    trap_pc <= interrupt_taken ? arch_next_pc : w_pc;
                    trap_cause <= interrupt_taken ? 32'h80000007 : w_cause;
                    trap_tval <= interrupt_taken ? 32'b0 : w_tval;
                end
                x_valid <= 0; m_valid <= 0; w_valid <= 0; x2_valid<=0;m2_valid<=0;w2_valid<=0;w2_trap<=0;
            end else if(secondary_exception_pending) begin
                // Retire the older normal instruction now; present the younger
                // exception on the primary retirement port in the next cycle.
                // No younger bus request or MDU operation may escape this step.
                x_valid<=0;x2_valid<=0;m_valid<=0;m2_valid<=0;
                w_valid<=1;w2_valid<=0;w2_trap<=0;w_we<=0;w_trap<=1;
                w_pc<=w2_pc;w_insn<=w2_insn;w_next_pc<=w2_pc+4;w_value<=0;w_addr<=0;w_rd<=0;
                w_wmask<=0;w_rmask<=0;w_wdata<=0;w_rdata<=0;w_cause<=w2_cause;w_tval<=w2_tval;
                w_prediction_hit<=0;w_prediction_taken<=0;w_prediction_wrong<=0;w_taken<=0;
            end else if (!halted) begin
                // WB always drains; no instruction can retire twice during a stall.
                w_valid <= m_done;
                w2_valid<=m_done && m2_valid && !m_trap && !m_fault && !m2_trap && !m2_fault;
                w2_trap<=m_done && m2_valid && !m_trap && !m_fault && (m2_trap || m2_fault);
                if (m_done) begin
                    w2_ras<=m2_ras;w2_next_pc<=m2_next_pc;w2_hit<=m2_hit;w2_pred_taken<=m2_pred_taken;w2_taken<=m2_taken;w2_wrong<=m2_wrong;w2_index<=m2_index;
                    w2_addr<=m2_addr;w2_wdata<=m2_wdata;w2_rdata<=dmem_rdata;w2_wmask<=m2_wmask;w2_rmask<=m2_rmask;
                    w2_cause<=m2_fault?(m2_store?32'd7:32'd5):m2_cause;w2_tval<=m2_fault?m2_addr:m2_tval;
                    w2_pc<=m2_pc;w2_insn<=m2_insn;w2_value<=m2_load?load_value:m2_value;w2_rd<=m2_rd;w2_we<=m2_we;
                    w_prediction_index<=m_prediction_index; w_prediction_ras<=m_prediction_ras;
                    w_taken<=m_taken; w_prediction_hit<=m_prediction_hit;
                    w_prediction_taken<=m_prediction_taken; w_prediction_wrong<=m_prediction_wrong;
                    w_pc <= m_pc; w_insn <= m_insn; w_next_pc <= m_next_pc;
                    w_rd <= m_rd; w_we <= m_we;
                    w_value <= m_load ? load_value : m_value;
                    w_addr <= m_addr; w_wmask <= m_wmask; w_rmask <= m_rmask;
                    w_wdata <= m_wdata; w_rdata <= dmem_rdata;
                    w_trap <= m_trap || m_fault;
                    w_cause <= m_fault ? (m_store ? 32'd7 : 32'd5) : m_cause;
                    w_tval <= m_fault ? m_addr : m_tval;
                end
                if (m_slot) begin
                    m_valid <= x_fire;
                    m2_valid<=x_fire && x2_valid && !ex_trap;
                    if (x_fire) begin
                        m2_ras<=x2_ras;m2_next_pc<=actual_next2;m2_hit<=x2_hit;m2_pred_taken<=x2_taken_pred;m2_taken<=x2_taking;m2_wrong<=prediction_wrong2;m2_index<=x2_index;
                        m2_load<=x2_load;m2_store<=x2_store;m2_trap<=ex2_trap;m2_cause<=ex2_cause;m2_tval<=ex2_tval;
                        m2_addr<=alu2_result;m2_wdata<=store_value2;m2_wmask<=x2_store?access_mask2:4'b0;m2_rmask<=x2_load?access_mask2:4'b0;m2_f3<=x2_insn[14:12];
                        m2_pc<=x2_pc;m2_insn<=x2_insn;m2_value<=x2_mop?md_result:(x2_jal || x2_jalr)?x2_pc+4:alu2_result;m2_rd<=x2_rd;m2_we<=x2_we;
                        m_prediction_index<=x_prediction_index; m_prediction_ras<=x_prediction_ras;
                        m_taken<=taking_branch; m_prediction_hit<=x_prediction_hit;
                        m_prediction_taken<=x_prediction_taken; m_prediction_wrong<=prediction_wrong;
                        m_pc <= x_pc; m_insn <= x_insn;
                        m_next_pc <= x_mret ? csr_mepc : taking_branch ? branch_target : x_pc + 4;
                        m_rd <= x_rd; m_we <= x_we;
                        m_value <= x_mop ? md_result : x_csr ? csr_read_data : (x_jal || x_jalr) ? x_pc + 4 : alu_result;
                        m_addr <= x_csr ? x_csr_new : alu_result; m_load <= x_load; m_store <= x_store;
                        m_wdata <= store_value;
                        m_wmask <= x_store ? access_mask : 4'b0;
                        m_rmask <= x_load ? access_mask : 4'b0;
                        m_f3 <= x_f3; m_trap <= ex_trap; m_cause <= ex_cause; m_tval <= ex_tval;
                    end
                end
                if (redirect) begin x_valid <= 0;x2_valid<=0;end
                else if (!x_valid || x_fire) begin
                    x_valid <= id_valid && id_ready;
                    x2_valid<=id_valid && id_ready && issue_pair;
                    if (id_valid && id_ready) begin
                        x2_predicted<=id2_next_pc;x2_hit<=id2_hit;x2_taken_pred<=id2_taken;x2_ras<=id2_ras;x2_index<=id2_index;
                        x2_pc<=id2_pc;x2_insn<=id2_insn;x2_r1<=id2_r1;x2_r2<=id2_r2;x2_imm<=id2_imm;
                        x2_rs1<=id2_rs1;x2_rs2<=id2_rs2;x2_rd<=id2_rd;x2_alu<=id2_alu;
                        x2_use1<=id2_use1;x2_use2<=id2_use2;x2_we<=id2_we;x2_pc_a<=id2_pc_a;x2_imm_b<=id2_imm_b;
                        x_prediction_index<=id_prediction_index; x_prediction_ras<=id_prediction_ras;
                        x_predicted_next_pc<=id_predicted_next_pc;
                        x_prediction_hit<=id_prediction_hit; x_prediction_taken<=id_prediction_taken;
                        x_pc <= id_pc; x_insn <= id_insn;
                        x_rs1 <= id_rs1; x_rs2 <= id_rs2; x_rd <= id_rd;
                        x_r1 <= id_r1; x_r2 <= id_r2; x_imm <= id_imm;
                        x_use1 <= id_use1 || (id_csr && !id_f3[2]); x_use2 <= id_use2; x_we <= id_we || id_csr;
                        x_alu <= id_alu; x_pc_a <= id_pc_a; x_imm_b <= id_imm_b;
                        x_load <= id_load; x_store <= id_store; x_branch <= id_branch;
                        x_jal <= id_jal; x_jalr <= id_jalr; x_f3 <= id_f3;
                        x_trap <= id_fetch_error || (id_illegal && !id_system) || id_ecall || id_ebreak;
                        if (id_fetch_error) begin x_cause <= 1; x_tval <= id_pc; end
                        else if (id_illegal && !id_system) begin x_cause <= 2; x_tval <= id_insn; end
                        else if (id_ebreak) begin x_cause <= 3; x_tval <= id_pc; end
                        else if (id_ecall) begin x_cause <= 11; x_tval <= 0; end
                        else begin x_cause <= 0; x_tval <= 0; end
                    end
                end else begin
                    // Preserve a WB bypass while EX is held by a slow memory.
                    // WB may disappear next cycle; retaining stale ID data is wrong.
                    x_r1 <= operand1;
                    x_r2 <= operand2;
                    x2_r1<=operand21;x2_r2<=operand22;
                end
            end
        end
    end
endmodule

`timescale 1ns/1ps
// M-only CSR subset. All CSR accesses are serialized by the CPU and write at WB.
module rv32_csr #(parameter [31:0] RESET_MTVEC=0, parameter [31:0] IMPL_ID=32'h00020501, parameter integer M_ENABLE=0, parameter [31:0] UARCH_CONFIG=0, parameter [31:0] ISSUE_CONFIG=32'hd1000000)(
    input wire clk,rst,
    input wire [11:0] read_address,
    output reg [31:0] read_data,
    output reg known,read_only,
    input wire write_enable,
    input wire [11:0] write_address,
    input wire [31:0] write_data,
    input wire trap_enter,
    input wire [31:0] trap_epc,trap_cause,trap_value,
    input wire mret,irq_timer,
    output wire irq_enabled,
    output reg [31:0] mtvec,mepc,
    input wire [63:0] cycle_count,retired_count,
    input wire [31:0] issued_pair_count,retired_pair_count,
    output reg [31:0] count_inhibit
);
    reg status_mie,status_mpie,timer_enable;
    reg [31:0] mscratch,mcause,mtval;
    wire [31:0] status_word=32'h00001800 | (status_mie?32'h8:0) | (status_mpie?32'h80:0);
    assign irq_enabled=status_mie && timer_enable && irq_timer;
    always @* begin
        known=1; read_only=read_address[11:10]==2'b11; read_data=0;
        case(read_address)
            12'h300: read_data=status_word;
            12'h301: read_data=32'h40000100 | (M_ENABLE ? 32'h00001000 : 0); // Fixed WARL: RV32 I or IM.
            12'h304: read_data=timer_enable?32'h80:0;
            12'h305: read_data=mtvec;
            12'h306,12'h310: read_data=0; // M-only mcounteren, little-endian mstatush.
            12'h320: read_data=count_inhibit;
            12'h340: read_data=mscratch;
            12'h341: read_data=mepc;
            12'h342: read_data=mcause;
            12'h343: read_data=mtval;
            12'h344: read_data=irq_timer?32'h80:0; // MTIP field is read-only.
            12'hb00,12'hc00: read_data=cycle_count[31:0];
            12'hb80,12'hc80: read_data=cycle_count[63:32];
            12'hb02,12'hc02: read_data=retired_count[31:0];
            12'hb82,12'hc82: read_data=retired_count[63:32];
            12'hf11,12'hf12,12'hf14: read_data=0;
            12'hf13: read_data=IMPL_ID;
            12'hfc1: read_data=ISSUE_CONFIG;
            12'hfc2: read_data=issued_pair_count;
            12'hfc3: read_data=retired_pair_count;
            12'hfc0: read_data=UARCH_CONFIG; // Custom machine read-only configuration.
            default: known=0;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            status_mie<=0; status_mpie<=0; timer_enable<=0;
            mtvec<={RESET_MTVEC[31:2],2'b00}; mepc<=0;
            mscratch<=0; mcause<=0; mtval<=0; count_inhibit<=0;
        end else if(trap_enter) begin
            mepc<={trap_epc[31:2],2'b00}; mcause<=trap_cause; mtval<=trap_value;
            status_mpie<=status_mie; status_mie<=0;
        end else if(mret) begin
            status_mie<=status_mpie; status_mpie<=1;
        end else if(write_enable) begin
            case(write_address)
                12'h300: begin status_mie<=write_data[3]; status_mpie<=write_data[7]; end
                12'h304: timer_enable<=write_data[7];
                12'h305: mtvec<={write_data[31:2],1'b0,(write_data[1:0]==1)};
                12'h320: count_inhibit<=write_data & 32'h5;
                12'h340: mscratch<=write_data;
                12'h341: mepc<={write_data[31:2],2'b00};
                12'h342: mcause<=write_data;
                12'h343: mtval<=write_data;
                // misa/mcounteren/mstatush are fixed WARL; mip.MTIP ignores writes.
                // Counter writes are handled by the owning CPU counter registers.
                default: begin end
            endcase
        end
    end
endmodule

`timescale 1ns/1ps

// Optional complete M extension. Zicsr/system legality is resolved in the core.
module rv32_decode #(parameter integer M_ENABLE=0, DIV_ENABLE=0) (
    input wire [31:0] insn,
    output wire [4:0] rs1, rs2, rd,
    output reg use_rs1, use_rs2, rd_write,
    output reg [31:0] imm,
    output reg [3:0] alu_op,
    output reg a_is_pc, b_is_imm,
    output reg is_load, is_store, is_branch, is_jal, is_jalr,
    output wire [2:0] funct3,
    output reg illegal, ecall, ebreak
);
    wire [6:0] opcode = insn[6:0];
    wire [6:0] funct7 = insn[31:25];
    assign rs1 = insn[19:15];
    assign rs2 = insn[24:20];
    assign rd = insn[11:7];
    assign funct3 = insn[14:12];
    always @* begin
        use_rs1 = 0; use_rs2 = 0; rd_write = 0;
        imm = 0; alu_op = `ALU_ADD; a_is_pc = 0; b_is_imm = 0;
        is_load = 0; is_store = 0; is_branch = 0;
        is_jal = 0; is_jalr = 0; illegal = 0; ecall = 0; ebreak = 0;
        case (opcode)
            7'h37: begin // LUI
                rd_write = 1; b_is_imm = 1; alu_op = `ALU_COPY;
                imm = {insn[31:12], 12'b0};
            end
            7'h17: begin // AUIPC
                rd_write = 1; a_is_pc = 1; b_is_imm = 1;
                imm = {insn[31:12], 12'b0};
            end
            7'h6f: begin // JAL
                rd_write = 1; is_jal = 1;
                imm = {{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
            end
            7'h67: begin // JALR
                rd_write = 1; use_rs1 = 1; is_jalr = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                if (funct3 != 0) illegal = 1;
            end
            7'h63: begin
                use_rs1 = 1; use_rs2 = 1; is_branch = 1;
                imm = {{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
                case (funct3)
                    3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h03: begin
                use_rs1 = 1; rd_write = 1; is_load = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                case (funct3)
                    3'd0,3'd1,3'd2,3'd4,3'd5: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h23: begin
                use_rs1 = 1; use_rs2 = 1; is_store = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:25],insn[11:7]};
                case (funct3)
                    3'd0,3'd1,3'd2: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h13: begin
                use_rs1 = 1; rd_write = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                case (funct3)
                    3'd0: alu_op = `ALU_ADD;
                    3'd2: alu_op = `ALU_SLT;
                    3'd3: alu_op = `ALU_SLTU;
                    3'd4: alu_op = `ALU_XOR;
                    3'd6: alu_op = `ALU_OR;
                    3'd7: alu_op = `ALU_AND;
                    3'd1: begin
                        alu_op = `ALU_SLL;
                        if (funct7 != 0) illegal = 1;
                    end
                    3'd5: begin
                        alu_op = insn[30] ? `ALU_SRA : `ALU_SRL;
                        if (funct7 != 0 && funct7 != 7'h20) illegal = 1;
                    end
                endcase
            end
            7'h33: begin
                use_rs1 = 1; use_rs2 = 1; rd_write = 1;
                case (funct3)
                    3'd0: alu_op = insn[30] ? `ALU_SUB : `ALU_ADD;
                    3'd1: alu_op = `ALU_SLL;
                    3'd2: alu_op = `ALU_SLT;
                    3'd3: alu_op = `ALU_SLTU;
                    3'd4: alu_op = `ALU_XOR;
                    3'd5: alu_op = insn[30] ? `ALU_SRA : `ALU_SRL;
                    3'd6: alu_op = `ALU_OR;
                    3'd7: alu_op = `ALU_AND;
                endcase
                if (funct7 != 0 && !(funct7 == 7'h20 && (funct3 == 0 || funct3 == 5)) && !(M_ENABLE && funct7==7'h01 && (DIV_ENABLE || !funct3[2])))
                    illegal = 1;
            end
            7'h0f: begin
                // Single hart, uncached, strongly ordered, no posted stores.
                // FENCE needs no extra operation. rd/rs1/fm are ignored as
                // required for forward compatibility; FENCE.I is unsupported.
                if (funct3 != 0) illegal = 1;
            end
            7'h73: begin
                if (insn == 32'h00000073) ecall = 1;
                else if (insn == 32'h00100073) ebreak = 1;
                else illegal = 1;
            end
            default: illegal = 1;
        endcase
    end
endmodule

`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0, DUAL_ENABLE=0, WIDE_FETCH=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    input wire rsp_second_valid,rsp_second_error,
    input wire [31:0] rsp_data_second,
    output wire [31:0] buf_second_next_pc,
    output wire buf_second_hit,buf_second_taken,buf_second_ras,
    output wire [PHT_BITS-1:0] buf_second_index,
    output wire buf_second_valid,buf_second_error,
    output wire [31:0] buf_second_pc,buf_second_insn,
    input wire buf_take_second,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    input wire buf_ready
);
    wire active,killed;
    wire [$clog2(DEPTH+1)-1:0] count;
    generate if(DUAL_ENABLE || WIDE_FETCH) begin: expanded
        rv32_fetch_dual #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),
        .PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(DEPTH),.BYPASS(BYPASS),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH)) impl(
        .clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),
        .req_valid(req_valid),.req_addr(req_addr),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .buf_valid(buf_valid),.buf_pc(buf_pc),.buf_insn(buf_insn),.buf_error(buf_error),.buf_ready(buf_ready),
        .buf_predicted_next_pc(buf_predicted_next_pc),.buf_prediction_hit(buf_prediction_hit),.buf_prediction_taken(buf_prediction_taken),
        .buf_prediction_ras(buf_prediction_ras),.buf_prediction_index(buf_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(bp_flush),
        .dbg_active(active),.dbg_killed(killed),.dbg_count(count),
        .rsp_second_valid(rsp_second_valid),.rsp_second_error(rsp_second_error),.rsp_data_second(rsp_data_second),
        .buf_second_valid(buf_second_valid),.buf_second_error(buf_second_error),.buf_second_pc(buf_second_pc),.buf_second_insn(buf_second_insn),
        .buf_second_next_pc(buf_second_next_pc),.buf_second_hit(buf_second_hit),.buf_second_taken(buf_second_taken),
        .buf_second_ras(buf_second_ras),.buf_second_index(buf_second_index),.buf_take_second(buf_take_second));
    end else begin: scalar
        rv32_fetch_scalar #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),
        .PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(DEPTH),.BYPASS(BYPASS)) impl(.clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),
        .req_valid(req_valid),.req_addr(req_addr),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .buf_valid(buf_valid),.buf_pc(buf_pc),.buf_insn(buf_insn),.buf_error(buf_error),.buf_ready(buf_ready),
        .buf_predicted_next_pc(buf_predicted_next_pc),.buf_prediction_hit(buf_prediction_hit),.buf_prediction_taken(buf_prediction_taken),
        .buf_prediction_ras(buf_prediction_ras),.buf_prediction_index(buf_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(bp_flush),
        .dbg_active(active),.dbg_killed(killed),.dbg_count(count));
        assign buf_second_next_pc=0;assign buf_second_hit=0;assign buf_second_taken=0;assign buf_second_ras=0;assign buf_second_index=0;
        assign buf_second_valid=1'b0;assign buf_second_error=1'b0;
        assign buf_second_pc=32'b0;assign buf_second_insn=32'b0;
    end endgenerate
endmodule

`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch_scalar #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    output wire dbg_active,dbg_killed,
    output wire [$clog2(DEPTH+1)-1:0] dbg_count,
    input wire buf_ready
);
    localparam PTR_BITS=DEPTH>1?$clog2(DEPTH):1;
    reg [31:0] pc,saved_target;
    reg active,killed;
    reg [PTR_BITS-1:0] read_ptr,write_ptr;
    reg [$clog2(DEPTH+1)-1:0] count;
    reg [31:0] pcs[0:DEPTH-1],insns[0:DEPTH-1],next_pcs[0:DEPTH-1];
    reg [3:0] meta[0:DEPTH-1];
    reg [PHT_BITS-1:0] indices[0:DEPTH-1];
    wire prediction_hit,prediction_taken,prediction_ras;
    wire [31:0] predicted_next_pc;
    wire [PHT_BITS-1:0] prediction_index;
    rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
        .clk(clk),.rst(rst),.query_pc(pc),.query_insn(rsp_data),.query_error(rsp_error),
        .hit(prediction_hit),.taken(prediction_taken),.next_pc(predicted_next_pc),.prediction_index(prediction_index),.ras_hit(prediction_ras),
        .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
        .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush)
    );
    wire stored=count!=0;
    wire pop=stored && buf_ready && !stop && !redirect;
    assign req_addr=pc;
    assign req_valid=!rst && (active || (!stop && !redirect && (count<DEPTH || pop)));
    wire response=req_valid && rsp_ready && !killed && !redirect && !stop;
    wire direct=BYPASS && !stored && response;
    wire push=response && !(direct && buf_ready);
    assign buf_valid=stored || direct;
    assign buf_pc=stored || !BYPASS ? pcs[read_ptr] : pc;
    assign buf_insn=stored || !BYPASS ? insns[read_ptr] : rsp_data;
    assign buf_predicted_next_pc=stored || !BYPASS ? next_pcs[read_ptr] : predicted_next_pc;
    assign {buf_error,buf_prediction_hit,buf_prediction_taken,buf_prediction_ras}=stored || !BYPASS ? meta[read_ptr] : {rsp_error,prediction_hit,prediction_taken,prediction_ras};
    assign buf_prediction_index=stored || !BYPASS ? indices[read_ptr] : prediction_index;
    integer k;
    always @(posedge clk) begin
        if(rst) begin
            pc<=RESET_PC; saved_target<=RESET_PC; active<=0; killed<=0;
            count<=0; read_ptr<=0; write_ptr<=0;
            for(k=0;k<DEPTH;k=k+1) begin pcs[k]<=0;insns[k]<=0;next_pcs[k]<=RESET_PC+4;meta[k]<=0;indices[k]<=0;end
        end else begin
            if(stop || redirect) begin count<=0;read_ptr<=0;write_ptr<=0;end
            else begin
                case({push,pop}) 2'b10:count<=count+1'b1; 2'b01:count<=count-1'b1; default:begin end endcase
                if(pop) read_ptr<=(read_ptr==DEPTH-1)?0:read_ptr+1'b1;
                if(push) begin
                    pcs[write_ptr]<=pc;insns[write_ptr]<=rsp_data;next_pcs[write_ptr]<=predicted_next_pc;
                    meta[write_ptr]<={rsp_error,prediction_hit,prediction_taken,prediction_ras};indices[write_ptr]<=prediction_index;
                    write_ptr<=(write_ptr==DEPTH-1)?0:write_ptr+1'b1;
                end
            end
            if(req_valid && rsp_ready) begin
                active<=0; killed<=0;
                pc<=killed?saved_target:predicted_next_pc;
            end else if(req_valid) active<=1;
            if(stop && active && !rsp_ready && !killed) begin killed<=1;saved_target<=pc;end
            if(redirect) begin
                if(active && !rsp_ready) begin killed<=1;saved_target<=redirect_pc;end
                else begin pc<=redirect_pc;killed<=0;end
            end
        end
    end
    assign dbg_active=active;assign dbg_killed=killed;assign dbg_count=count;
endmodule

`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch_dual #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0, DUAL_ENABLE=0, WIDE_FETCH=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    input wire rsp_second_valid,rsp_second_error,
    input wire [31:0] rsp_data_second,
    output wire [31:0] buf_second_next_pc,
    output wire buf_second_hit,buf_second_taken,buf_second_ras,
    output wire [PHT_BITS-1:0] buf_second_index,
    output wire buf_second_valid,buf_second_error,
    output wire [31:0] buf_second_pc,buf_second_insn,
    input wire buf_take_second,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    output wire dbg_active,dbg_killed,
    output wire [$clog2(DEPTH+1)-1:0] dbg_count,
    input wire buf_ready
);
    // DEPTH must be at least two. Reserve the maximum response width before
    // issuing; no combinational dependence on the consumer's pair decision.
    localparam ITEM_BITS=100+PHT_BITS, RESERVE=WIDE_FETCH?2:1;
    reg [31:0] pc,saved_target;
    reg active,killed;
    reg [$clog2(DEPTH+1)-1:0] count,next_count;
    reg [ITEM_BITS-1:0] items[0:DEPTH-1],next_items[0:DEPTH-1];
    wire hit0,taken0,ras0,hit1,taken1,ras1;
    wire [31:0] next0,next1;
    wire [PHT_BITS-1:0] index0,index1;
    wire [31:0] second_pc=pc+4;
    rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
        .clk(clk),.rst(rst),.query_pc(pc),.query_insn(rsp_data),.query_error(rsp_error),
        .hit(hit0),.taken(taken0),.next_pc(next0),.prediction_index(index0),.ras_hit(ras0),
        .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
        .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush));
    generate if(WIDE_FETCH) begin: query_second
        // Identical retirement training, independent query address. GHR/RAS
        // remain committed state; both prediction indices travel with the words.
        rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
            .clk(clk),.rst(rst),.query_pc(second_pc),.query_insn(rsp_data_second),.query_error(rsp_second_error),
            .hit(hit1),.taken(taken1),.next_pc(next1),.prediction_index(index1),.ras_hit(ras1),
            .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
            .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush));
    end else begin: query_single
        assign hit1=0;assign taken1=0;assign ras1=0;assign next1=second_pc+4;assign index1=0;
    end endgenerate
    assign req_addr=pc;
    assign req_valid=!rst && (active || (!stop && !redirect && count<=DEPTH-RESERVE));
    wire second_ok=WIDE_FETCH && rsp_second_valid && !rsp_error && next0==second_pc;
    wire live=req_valid && rsp_ready && !killed && !stop && !redirect;
    wire [ITEM_BITS-1:0] response0={pc,rsp_data,next0,rsp_error,hit0,taken0,ras0,index0};
    wire [ITEM_BITS-1:0] response1={second_pc,rsp_data_second,next1,rsp_second_error,hit1,taken1,ras1,index1};
    wire [ITEM_BITS-1:0] head0=count!=0?items[0]:response0;
    wire [ITEM_BITS-1:0] head1=count>1?items[1]:count==1?response0:response1;
    assign buf_valid=count!=0 || (BYPASS && live);
    assign buf_second_valid=count>1 || (BYPASS && live && (count==1 || second_ok));
    assign {buf_pc,buf_insn,buf_predicted_next_pc,buf_error,buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,buf_prediction_index}=head0;
    wire [31:0] unused_next;
    wire [2:0] unused_meta;
    wire [PHT_BITS-1:0] unused_index;
    assign {buf_second_pc,buf_second_insn,buf_second_next_pc,buf_second_error,buf_second_hit,buf_second_taken,buf_second_ras,buf_second_index}=head1;
    integer consumed,stored_pop,direct_pop,remaining,incoming,k;
    always @* begin
        incoming=live?(second_ok?2:1):0;
        consumed=!stop && !redirect && buf_valid && buf_ready ? ((DUAL_ENABLE && buf_take_second && buf_second_valid)?2:1):0;
        stored_pop=consumed>count?count:consumed;
        direct_pop=consumed-stored_pop;
        remaining=count-stored_pop;
        next_count=count+incoming-consumed;
        for(k=0;k<DEPTH;k=k+1) begin
            next_items[k]=0;
            if(k<remaining) next_items[k]=items[k+stored_pop];
            if(incoming>direct_pop && k==remaining) next_items[k]=direct_pop==0?response0:response1;
            if(incoming-direct_pop==2 && k==remaining+1) next_items[k]=response1;
        end
    end
    integer q;
    always @(posedge clk) begin
        if(rst) begin
            pc<=RESET_PC;saved_target<=RESET_PC;active<=0;killed<=0;count<=0;
            for(q=0;q<DEPTH;q=q+1) items[q]<=0;
        end else begin
            if(stop || redirect) count<=0;
            else begin
                count<=next_count;
                for(q=0;q<DEPTH;q=q+1) items[q]<=next_items[q];
            end
            if(req_valid && rsp_ready) begin
                active<=0;killed<=0;
                pc<=killed?saved_target:(second_ok?next1:next0);
            end else if(req_valid) active<=1;
            if(stop && active && !rsp_ready && !killed) begin killed<=1;saved_target<=pc;end
            if(redirect) begin
                if(active && !rsp_ready) begin killed<=1;saved_target<=redirect_pc;end
                else begin pc<=redirect_pc;killed<=0;end
            end
        end
    end
    assign dbg_active=active;assign dbg_killed=killed;assign dbg_count=count;
endmodule

`timescale 1ns/1ps
// One outstanding operation. Operands are captured once; response stays stable
// until consumed. Reset/kill discards any in-flight operation and response.
// Four multiply variants share ONE unsigned 32x32 product. Signed high halves
// are corrected modulo 2^32, avoiding a separate signed 33x33 multiplier.
module rv32_muldiv #(parameter FAST_MUL=0, DIV_ENABLE=0) (
    input wire clk,rst,kill,
    input wire req_valid, output wire req_ready,
    input wire [2:0] req_op,
    input wire [31:0] req_a,req_b,
    output wire rsp_valid,input wire rsp_ready,
    output reg [31:0] result
);
    localparam IDLE=0,MUL_PRODUCT=1,MUL_CORRECT=2,DIVIDE=3,DONE=4;
    reg [2:0] state;
    reg [2:0] op;
    reg [31:0] a,b;
    reg [63:0] product;
    reg a_negative,b_negative;
    reg [31:0] quotient,remainder,divisor;
    reg quotient_negative,remainder_negative;
    reg [5:0] steps;
    wire [2:0] selected_op = DIV_ENABLE ? req_op : {1'b0,req_op[1:0]};
    wire signed_div=(selected_op==3'd4 || selected_op==3'd6);
    wire [31:0] abs_a=signed_div && req_a[31] ? 32'b0-req_a : req_a;
    wire [31:0] abs_b=signed_div && req_b[31] ? 32'b0-req_b : req_b;
    wire [32:0] trial={remainder,quotient[31]};
    wire subtract=trial>={1'b0,divisor};
    wire [32:0] next_remainder=subtract ? trial-{1'b0,divisor} : trial;
    wire [31:0] next_quotient={quotient[30:0],subtract};
    wire [31:0] multiply_a=FAST_MUL?req_a:a;
    wire [31:0] multiply_b=FAST_MUL?req_b:b;
    wire [63:0] unsigned_product;
    pango_evolve_mul multiplier (.a(multiply_a),.b(multiply_b),.p(unsigned_product),.clk(clk),.rst(rst),.ce(1'b1));
    wire [31:0] signed_high=product[63:32]-(a_negative?b:32'b0)-(b_negative?a:32'b0);
    assign req_ready=(state==IDLE) && !rst && !kill;
    assign rsp_valid=(state==DONE) && !rst && !kill;
    always @(posedge clk) begin
        if(rst || kill) begin
            state<=IDLE; result<=0; op<=0; a<=0; b<=0; product<=0;
            a_negative<=0; b_negative<=0; quotient<=0; remainder<=0; divisor<=0;
            quotient_negative<=0; remainder_negative<=0; steps<=0;
        end else case(state)
            IDLE: if(req_valid) begin
                op<=selected_op; a<=req_a; b<=req_b;
                if(!selected_op[2]) begin
                    a_negative<=(selected_op==1 || selected_op==2) && req_a[31];
                    b_negative<=(selected_op==1) && req_b[31];
                    if(FAST_MUL) begin
                        product<=unsigned_product;
                        if(selected_op==0)begin result<=unsigned_product[31:0];state<=DONE;end
                        else state<=MUL_CORRECT;
                    end else state<=MUL_PRODUCT;
                end else if(req_b==0) begin
                    result<=selected_op[1]?req_a:32'hffffffff; state<=DONE;
                end else if(signed_div && req_a==32'h80000000 && req_b==32'hffffffff) begin
                    result<=selected_op[1]?32'b0:32'h80000000; state<=DONE;
                end else begin
                    quotient<=abs_a; divisor<=abs_b; remainder<=0; steps<=32;
                    quotient_negative<=signed_div && (req_a[31]^req_b[31]);
                    remainder_negative<=signed_div && req_a[31];
                    state<=DIVIDE;
                end
            end
            MUL_PRODUCT: begin product<=unsigned_product; state<=MUL_CORRECT; end
            MUL_CORRECT: begin result<=op==0?product[31:0]:signed_high; state<=DONE; end
            DIVIDE: begin
                quotient<=next_quotient; remainder<=next_remainder[31:0]; steps<=steps-1'b1;
                if(steps==1) begin
                    result<=op[1] ? (remainder_negative?32'b0-next_remainder[31:0]:next_remainder[31:0]) :
                                    (quotient_negative?32'b0-next_quotient:next_quotient);
                    state<=DONE;
                end
            end
            DONE: if(rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule

`timescale 1ns/1ps
// Retire-trained BTB, committed-history gshare and committed return stack.
// PHT training uses the index saved at prediction, not a newly computed index.
module rv32_predictor #(
    parameter integer ENABLE=1, INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0
)(
    input wire clk,rst,
    input wire [31:0] query_pc,query_insn,
    input wire query_error,
    output wire hit,taken,
    output wire [31:0] next_pc,
    output wire [PHT_BITS-1:0] prediction_index,
    output wire ras_hit,
    input wire update_valid,update_conditional,update_taken,
    input wire [31:0] update_pc,update_target,update_insn,
    input wire [PHT_BITS-1:0] update_index,
    input wire context_flush
);
    localparam integer ENTRIES=1<<INDEX_BITS;
    wire [6:0] opcode=query_insn[6:0];
    wire [2:0] f3=query_insn[14:12];
    wire conditional=opcode==7'h63 && (f3==0 || f3==1 || f3==4 || f3==5 || f3==6 || f3==7);
    wire control=conditional || opcode==7'h6f || (opcode==7'h67 && f3==0);
    generate if(ENABLE) begin: table_enabled
        reg [ENTRIES-1:0] valid;
        reg [29-INDEX_BITS:0] tags[0:ENTRIES-1];
        reg [29:0] targets[0:ENTRIES-1];
        reg [1:0] direction[0:ENTRIES-1];
        wire [INDEX_BITS-1:0] qi=query_pc[INDEX_BITS+1:2];
        wire [INDEX_BITS-1:0] ui=update_pc[INDEX_BITS+1:2];
        wire same_entry=valid[ui] && tags[ui]==update_pc[31:INDEX_BITS+2];
        wire btb_hit=!rst && !query_error && control && valid[qi] && tags[qi]==query_pc[31:INDEX_BITS+2];
        wire direction_taken;
        wire [31:0] ras_target;
        assign hit=btb_hit || ras_hit;
        assign taken=ras_hit || (btb_hit && (!conditional || direction_taken));
        assign next_pc=ras_hit ? ras_target : taken ? {targets[qi],2'b00} : query_pc+32'd4;
        always @(posedge clk) begin
            if(rst) valid<=0;
            else if(update_valid) begin
                if(update_taken) begin
                    valid[ui]<=1;
                    tags[ui]<=update_pc[31:INDEX_BITS+2];
                    targets[ui]<=update_target[31:2];
                    if(!update_conditional) direction[ui]<=2'b11;
                    else if(!same_entry) direction[ui]<=2'b10;
                    else if(direction[ui]!=2'b11) direction[ui]<=direction[ui]+2'b01;
                end else if(update_conditional && same_entry && direction[ui]!=2'b00)
                    direction[ui]<=direction[ui]-2'b01;
            end
        end
        if(GSHARE_ENABLE) begin: gshare
            localparam integer PHT_ENTRIES=1<<PHT_BITS;
            reg [PHT_BITS-1:0] history;
            reg [PHT_ENTRIES-1:0] pht_valid;
            reg [1:0] counters[0:PHT_ENTRIES-1];
            wire [PHT_BITS-1:0] index=query_pc[PHT_BITS+1:2]^history;
            assign prediction_index=index;
            assign direction_taken=pht_valid[index] && counters[index][1];
            always @(posedge clk) begin
                if(rst) begin history<=0; pht_valid<=0; end
                else begin
                    if(context_flush) history<=0;
                    else if(update_valid && update_conditional) history<={history[PHT_BITS-2:0],update_taken};
                    if(update_valid && update_conditional) begin
                        pht_valid[update_index]<=1;
                        if(!pht_valid[update_index]) counters[update_index]<=update_taken?2'b10:2'b01;
                        else if(update_taken && counters[update_index]!=3) counters[update_index]<=counters[update_index]+1'b1;
                        else if(!update_taken && counters[update_index]!=0) counters[update_index]<=counters[update_index]-1'b1;
                    end
                end
            end
        end else begin: bimodal
            assign direction_taken=direction[qi][1];
            assign prediction_index={PHT_BITS{1'b0}};
        end
        if(RAS_DEPTH>0) begin: ras
            reg [31:0] stack[0:RAS_DEPTH-1];
            reg [$clog2(RAS_DEPTH+1)-1:0] count;
            wire u_rd_link=(update_insn[11:7]==1 || update_insn[11:7]==5);
            wire u_rs_link=(update_insn[19:15]==1 || update_insn[19:15]==5);
            wire u_jalr=update_insn[6:0]==7'h67 && update_insn[14:12]==0;
            wire push=u_rd_link && (update_insn[6:0]==7'h6f || u_jalr);
            wire pop=u_jalr && u_rs_link && (!u_rd_link || update_insn[11:7]!=update_insn[19:15]);
            wire q_rd_link=(query_insn[11:7]==1 || query_insn[11:7]==5);
            wire q_rs_link=(query_insn[19:15]==1 || query_insn[19:15]==5);
            wire q_pop=q_rs_link && (!q_rd_link || query_insn[11:7]!=query_insn[19:15]);
            // Nonzero-offset JALR uses the BTB; only zero-offset returns use RAS.
            assign ras_hit=!rst && !query_error && opcode==7'h67 && f3==0 && query_insn[31:20]==0 && q_pop && count!=0;
            assign ras_target=stack[0];
            integer k;
            always @(posedge clk) begin
                if(rst || context_flush) count<=0;
                else if(update_valid) begin
                    if(push && pop) begin
                        stack[0]<=update_pc+4;
                        if(count==0) count<=1;
                    end else if(push) begin
                        for(k=RAS_DEPTH-1;k>0;k=k-1) stack[k]<=stack[k-1];
                        stack[0]<=update_pc+4;
                        if(count<RAS_DEPTH) count<=count+1'b1;
                    end else if(pop && count!=0) begin
                        for(k=0;k<RAS_DEPTH-1;k=k+1) stack[k]<=stack[k+1];
                        count<=count-1'b1;
                    end
                end
            end
        end else begin: ras_disabled
            assign ras_hit=1'b0;
            assign ras_target=32'b0;
        end
    end else begin: table_disabled
        assign hit=1'b0;
        assign taken=1'b0;
        assign ras_hit=1'b0;
        assign prediction_index={PHT_BITS{1'b0}};
        assign next_pc=query_pc+32'd4;
    end endgenerate
endmodule

`timescale 1ns/1ps
// Two asynchronous read ports, one rising-edge write port. x0 is immutable.
// Same-cycle write-through is intentional and part of the ID/WB contract.
module rv32_regfile #(parameter integer DUAL_ENABLE=0) (
    input wire clk, rst,
    input wire [4:0] rs1, rs2,
    output wire [31:0] rdata1, rdata2,
    input wire we,
    input wire [4:0] rd,
    input wire [31:0] wdata,
    input wire [4:0] rs3,rs4,rd2,
    output wire [31:0] rdata3,rdata4,
    input wire we2,
    input wire [31:0] wdata2
);
    reg [31:0] regs [0:31];
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if(DUAL_ENABLE) begin
            for(i=1;i<32;i=i+1) begin
                if(we2 && rd2==i) regs[i]<=wdata2;
                else if(we && rd==i) regs[i]<=wdata;
            end
        end else if (we && rd != 0) regs[rd] <= wdata;
    end
    assign rdata1 = rs1 == 0 ? 32'b0 :
                    (DUAL_ENABLE && we2 && rd2==rs1 ? wdata2 : we && rd == rs1 ? wdata : regs[rs1]);
    assign rdata2 = rs2 == 0 ? 32'b0 :
                    (DUAL_ENABLE && we2 && rd2==rs2 ? wdata2 : we && rd == rs2 ? wdata : regs[rs2]);
    assign rdata3 = !DUAL_ENABLE || rs3==0 ? 32'b0 :
                    (we2 && rd2==rs3 ? wdata2 : we && rd==rs3 ? wdata : regs[rs3]);
    assign rdata4 = !DUAL_ENABLE || rs4==0 ? 32'b0 :
                    (we2 && rd2==rs4 ? wdata2 : we && rd==rs4 ? wdata : regs[rs4]);
endmodule

`timescale 1ns/1ps
module rv32_gpio #(
    parameter integer WIDTH = 8
) (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire ready,
    output reg [31:0] rdata,
    output reg error,
    input wire [WIDTH-1:0] pins_in,
    output reg [WIDTH-1:0] pins_out, pins_oe
);
    reg [WIDTH-1:0] input_meta /* synthesis syn_preserve=1 */;
    reg [WIDTH-1:0] input_sync /* synthesis syn_preserve=1 */;
    wire [31:0] byte_mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    wire [31:0] masked = wdata & byte_mask;
    assign ready = valid;
    always @* begin
        error = 0; rdata = 0;
        case (addr[11:2])
            10'h000: rdata = {{(32-WIDTH){1'b0}},pins_out};
            10'h001: rdata = {{(32-WIDTH){1'b0}},pins_oe};
            10'h002: begin rdata = {{(32-WIDTH){1'b0}},input_sync}; error = write; end
            10'h003,10'h004,10'h005: error = !write;
            default: error = 1;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            pins_out <= 0; pins_oe <= 0; input_meta <= 0; input_sync <= 0;
        end else begin
            input_meta <= pins_in; input_sync <= input_meta;
            if (valid && ready && write && !error) begin
                case (addr[11:2])
                    10'h000: pins_out <= (pins_out & ~byte_mask[WIDTH-1:0]) | masked[WIDTH-1:0];
                    10'h001: pins_oe <= (pins_oe & ~byte_mask[WIDTH-1:0]) | masked[WIDTH-1:0];
                    10'h003: pins_out <= pins_out | masked[WIDTH-1:0];
                    10'h004: pins_out <= pins_out & ~masked[WIDTH-1:0];
                    10'h005: pins_out <= pins_out ^ masked[WIDTH-1:0];
                endcase
            end
        end
    end
endmodule

`timescale 1ns/1ps
// Read-only hardware identity + coherent snapshots of ten 32-bit counters.
// Counters wrap modulo 2^32; snapshots are cumulative, not CoreMark intervals.
module rv32_monitor #(
    parameter integer ENABLE=1,CLOCK_HZ=25000000,CACHE_BYTES=1024,LINE_BYTES=16,SETS=32,BP_ENTRIES=32,
    parameter [31:0] CONFIG=32'h1f,
    parameter integer FIRST_WAIT=0,BEAT_GAP=0
)(
    input wire clk,rst,valid,write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    input wire [319:0] live_counts,
    output wire ready,
    output reg [31:0] rdata,
    output reg error
);
    reg [31:0] snapshot[0:9];
    reg [31:0] sequence_number;
    integer k;
    wire [11:0] aligned={addr[11:2],2'b00};
    assign ready=ENABLE && valid && !rst;
    always @* begin
        rdata=0; error=0;
        if(!ENABLE) error=1;
        else if(write) begin
            if(aligned!=12'h024 || addr[1:0]!=0 || wstrb!=4'hf || wdata!=1) error=1;
        end else case(aligned)
            12'h000:rdata=32'h43414333;
            12'h004:rdata=CONFIG;
            12'h008:rdata=CLOCK_HZ;
            12'h00c:rdata=CACHE_BYTES;
            12'h010:rdata=LINE_BYTES;
            12'h014:rdata=SETS;
            12'h018:rdata=BP_ENTRIES;
            12'h01c:rdata={BEAT_GAP[15:0],FIRST_WAIT[15:0]};
            12'h020:rdata=sequence_number;
            12'h024:rdata=0;
            default: begin
                if(aligned>=12'h080 && aligned<=12'h0a4) rdata=snapshot[(aligned-12'h080)>>2];
                else if(aligned>=12'h100 && aligned<=12'h124) rdata=live_counts[((aligned-12'h100)>>2)*32+:32];
                else error=1;
            end
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin sequence_number<=0; for(k=0;k<10;k=k+1) snapshot[k]<=0; end
        else if(ready && write && !error) begin
            sequence_number<=sequence_number+1;
            for(k=0;k<10;k=k+1) snapshot[k]<=live_counts[k*32+:32];
        end
    end
endmodule

`timescale 1ns/1ps
// Board-independent SoC top. clk/rst must already be conditioned by a board wrapper.
module rv32_soc #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer M_ENABLE=0,
    parameter integer BP_ENABLE=1,
    parameter integer BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, FETCH_DEPTH=1, FETCH_BYPASS=0, LOAD_FORWARD=0,
    parameter integer DUAL_ENABLE=0, WIDE_FETCH=0, PAIR_BRANCH=0, PAIR_MEMORY=0, PAIR_JALR=0, FAST_MUL=0, FAST_STORE=0, PAIR_MUL=0,
    parameter integer BURST_BACKEND=1, BURST_FILL=1, MEM_FIRST_WAIT=0, MEM_BEAT_GAP=0,
    parameter integer ICACHE_ENABLE=1,
    parameter integer DCACHE_ENABLE=1,
    parameter integer CACHE_SET_BITS=5,
    parameter integer CACHE_LINE_WORD_BITS=2,
    parameter [31:0] RESET_MTVEC=0,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire clk, rst,
    input wire uart_rx,
    output wire uart_tx,
    input wire [7:0] gpio_in,
    output wire [7:0] gpio_out, gpio_oe,
    output wire timer_pending,
    output wire halted,
    output wire [31:0] trap_pc, trap_cause, trap_tval,
    output wire debug_commit, debug_trap,
    output wire [31:0] debug_pc, debug_insn
);
    wire iv,ir,ie,dv,dw,dr,de;
    wire [31:0] ia,idata,da,wd,rdata,idata_second;
    wire i_second_valid;
    wire [3:0] ws;
    wire biv,bir,bie,bdv,bdw,bdr,bde;
    wire [31:0] bia,bidata,bda,bwd,brdata;
    wire [3:0] bws;
    wire icv,icr,icw,irv,irr,ire,irl,dcv,dcr,dcw,drv,drr,dre,drl;
    wire [31:0] ica,icd,ird,dca,dcd,drd; wire [3:0] ics,dcs; wire [7:0] icl,dcl;
    wire cv,cr,cw,ci,rv,rr,re,rl; wire [31:0] ca,cd,rd; wire [3:0] cs; wire [7:0] cl;
    wire [31:0] ih,im,dh,dm,wh,wm;
    reg [31:0] read_commands,burst_commands,read_beats,write_responses;
    reg monitor_memory,monitor_write;
    wire command_memory=ca<32'h8000 || (ca>=32'h20000000 && ca<32'h20008000);
    wire [319:0] monitor_counts={write_responses,read_beats,burst_commands,read_commands,wm,wh,dm,dh,im,ih};
    localparam [31:0] HARDWARE_CONFIG=(M_ENABLE<<5)|(BP_ENABLE<<4)|(BURST_FILL<<3)|(BURST_BACKEND<<2)|(DCACHE_ENABLE<<1)|ICACHE_ENABLE;
    always @(posedge clk) begin
        if(rst) begin read_commands<=0; burst_commands<=0; read_beats<=0; write_responses<=0; monitor_memory<=0; monitor_write<=0; end
        else begin
            if(cv && cr) begin
                monitor_memory<=command_memory; monitor_write<=cw;
                if(command_memory && !cw) begin
                    read_commands<=read_commands+1;
                    if(cl!=0) burst_commands<=burst_commands+1;
                end
            end
            if(rv && rr && monitor_memory) begin
                if(monitor_write) write_responses<=write_responses+1;
                else read_beats<=read_beats+1;
            end
        end
    end

    rv32_core #(.RESET_MTVEC(RESET_MTVEC),.M_ENABLE(M_ENABLE),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.FETCH_DEPTH(FETCH_DEPTH),.FETCH_BYPASS(FETCH_BYPASS),.LOAD_FORWARD(LOAD_FORWARD),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH),.PAIR_BRANCH(PAIR_BRANCH),.PAIR_MEMORY(PAIR_MEMORY),.PAIR_JALR(PAIR_JALR),.FAST_MUL(FAST_MUL),.FAST_STORE(FAST_STORE),.PAIR_MUL(PAIR_MUL)) cpu (
        .clk(clk),.rst(rst),.irq_timer(timer_pending),.interrupt_taken(),.imem_valid(iv),.imem_addr(ia),.imem_ready(ir),.imem_rdata(idata),.imem_error(ie),.imem_second_valid(i_second_valid),.imem_second_error(1'b0),.imem_rdata_second(idata_second),
        .dmem_valid(dv),.dmem_write(dw),.dmem_addr(da),.dmem_wdata(wd),.dmem_wstrb(ws),
        .dmem_ready(dr),.dmem_rdata(rdata),.dmem_error(de),
        .halted(halted),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .retire_valid(debug_commit),.retire_trap(debug_trap),.retire_pc(debug_pc),.retire_insn(debug_insn),
        .retire_rd_we(),.retire_next_pc(),.retire_rd(),.retire_rd_data(),
        .retire_mem_addr(),.retire_mem_wdata(),.retire_mem_rdata(),.retire_mem_wmask(),.retire_mem_rmask(),
        .retire_cause(),.retire_tval(),.cycles(),.instret(),.load_stall_cycles(),.data_wait_cycles(),.fetch_wait_cycles(),.redirect_count()
        ,.retire2_valid(),.retire2_rd_we(),.retire2_pc(),.retire2_insn(),.retire2_next_pc(),.retire2_rd_data(),.retire2_rd()
        ,.retire2_mem_addr(),.retire2_mem_wdata(),.retire2_mem_rdata(),.retire2_mem_wmask(),.retire2_mem_rmask()
    );
    rv32_icache #(.WIDE_FETCH(WIDE_FETCH),.BURST_INTERFACE(BURST_BACKEND),.BURST_FILL(BURST_FILL),.ENABLE(ICACHE_ENABLE),.SET_BITS(CACHE_SET_BITS),.LINE_WORD_BITS(CACHE_LINE_WORD_BITS)) i_cache (
        .clk(clk),.rst(rst),.valid(iv),.addr(ia),.ready(ir),.rdata(idata),.error(ie),.second_valid(i_second_valid),.rdata_second(idata_second),
        .mem_valid(biv),.mem_addr(bia),.mem_ready(bir),.mem_rdata(bidata),.mem_error(bie),
        .cmd_valid(icv),.cmd_ready(icr),.cmd_write(icw),.cmd_addr(ica),.cmd_wdata(icd),.cmd_wstrb(ics),.cmd_len(icl),
        .rsp_valid(irv),.rsp_ready(irr),.rsp_data(ird),.rsp_error(ire),.rsp_last(irl),
        .read_hits(ih),.read_misses(im),.refill_words(),.refill_errors());
    rv32_dcache #(.FAST_STORE(FAST_STORE),.BURST_INTERFACE(BURST_BACKEND),.BURST_FILL(BURST_FILL),.ENABLE(DCACHE_ENABLE),.SET_BITS(CACHE_SET_BITS),.LINE_WORD_BITS(CACHE_LINE_WORD_BITS)) d_cache (
        .clk(clk),.rst(rst),.valid(dv),.write(dw),.addr(da),.wdata(wd),.wstrb(ws),.ready(dr),.rdata(rdata),.error(de),
        .mem_valid(bdv),.mem_write(bdw),.mem_addr(bda),.mem_wdata(bwd),.mem_wstrb(bws),.mem_ready(bdr),.mem_rdata(brdata),.mem_error(bde),
        .cmd_valid(dcv),.cmd_ready(dcr),.cmd_write(dcw),.cmd_addr(dca),.cmd_wdata(dcd),.cmd_wstrb(dcs),.cmd_len(dcl),
        .rsp_valid(drv),.rsp_ready(drr),.rsp_data(drd),.rsp_error(dre),.rsp_last(drl),
        .read_hits(dh),.read_misses(dm),.write_hits(wh),.write_misses(wm),.bypass_requests(),.refill_words(),.refill_errors());
    rv32_burst_arbiter arbiter (
        .clk(clk),.rst(rst),.i_valid(icv),.i_ready(icr),.i_write(icw),.i_addr(ica),.i_wdata(icd),.i_wstrb(ics),.i_len(icl),
        .i_rsp_valid(irv),.i_rsp_ready(irr),.i_rsp_data(ird),.i_rsp_error(ire),.i_rsp_last(irl),
        .d_valid(dcv),.d_ready(dcr),.d_write(dcw),.d_addr(dca),.d_wdata(dcd),.d_wstrb(dcs),.d_len(dcl),
        .d_rsp_valid(drv),.d_rsp_ready(drr),.d_rsp_data(drd),.d_rsp_error(dre),.d_rsp_last(drl),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_instr(ci),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_data(rd),.rsp_error(re),.rsp_last(rl));
    rv32_soc_fabric #(.MONITOR_ENABLE(1),.HW_CONFIG(HARDWARE_CONFIG),.CACHE_BYTES(2*(1<<CACHE_SET_BITS)*(4<<CACHE_LINE_WORD_BITS)),
        .LINE_BYTES(4<<CACHE_LINE_WORD_BITS),.CACHE_SETS(1<<CACHE_SET_BITS),.BP_ENTRIES(1<<BP_INDEX_BITS),
        .BURST_INTERFACE(BURST_BACKEND),.FIRST_WAIT(MEM_FIRST_WAIT),.BEAT_GAP(MEM_BEAT_GAP),.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.ROM_FILE(ROM_FILE)) fabric (
        .clk(clk),.rst(rst),.iv(biv),.ia(bia),.ir(bir),.idata(bidata),.ie(bie),
        .dv(bdv),.dw(bdw),.da(bda),.wd(bwd),.ws(bws),.dr(bdr),.rdata(brdata),.de(bde),
        .b_cmd_valid(cv),.b_cmd_ready(cr),.b_cmd_write(cw),.b_cmd_instr(ci),.b_cmd_addr(ca),.b_cmd_wdata(cd),.b_cmd_wstrb(cs),.b_cmd_len(cl),
        .b_rsp_valid(rv),.b_rsp_ready(rr),.b_rsp_data(rd),.b_rsp_error(re),.b_rsp_last(rl),
        .monitor_counts(monitor_counts),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe),.timer_pending(timer_pending)
    );
endmodule

`timescale 1ns/1ps
module rv32_soc_fabric #(
    parameter integer BURST_INTERFACE=0, FIRST_WAIT=0, BEAT_GAP=0,
    parameter integer MONITOR_ENABLE=0,CACHE_BYTES=1024,LINE_BYTES=16,CACHE_SETS=32,BP_ENTRIES=32,
    parameter [31:0] HW_CONFIG=0,
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer ROM_BYTES = 32768,
    parameter integer RAM_BYTES = 32768,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire clk, rst,
    input wire iv,
    input wire [31:0] ia,
    output wire ir,
    output wire [31:0] idata,
    output wire ie,
    input wire dv, dw,
    input wire [31:0] da, wd,
    input wire [3:0] ws,
    output reg dr,
    output reg [31:0] rdata,
    output reg de,
    input wire uart_rx,
    output wire uart_tx,
    input wire [7:0] gpio_in,
    output wire [7:0] gpio_out, gpio_oe,
    output wire timer_pending,
    input wire b_cmd_valid,b_cmd_write,b_cmd_instr,
    input wire [31:0] b_cmd_addr,b_cmd_wdata,
    input wire [3:0] b_cmd_wstrb,
    input wire [7:0] b_cmd_len,
    output wire b_cmd_ready,
    output wire b_rsp_valid,b_rsp_error,b_rsp_last,
    output wire [31:0] b_rsp_data,
    input wire b_rsp_ready,
    input wire [319:0] monitor_counts
);
    reg active,to_memory,periph_done,saved_write,saved_error;
    reg [31:0] saved_address,saved_wdata,saved_rdata;
    reg [3:0] saved_strobes;
    wire memory_command=b_cmd_instr || b_cmd_len!=0 || b_cmd_addr<ROM_BYTES ||
                        (b_cmd_addr>=32'h20000000 && b_cmd_addr<32'h20000000+RAM_BYTES);
    wire mc_ready,mr_valid,mr_error,mr_last; wire [31:0] mr_data;
    wire pv=BURST_INTERFACE ? (active && !to_memory && !periph_done) : dv;
    wire pw=BURST_INTERFACE ? saved_write : dw;
    wire [31:0] pa=BURST_INTERFACE ? saved_address : da;
    wire [31:0] pd=BURST_INTERFACE ? saved_wdata : wd;
    wire [3:0] ps=BURST_INTERFACE ? saved_strobes : ws;
    wire mem_select=pa<ROM_BYTES || (pa>=32'h20000000 && pa<32'h20000000+RAM_BYTES);
    wire uart_select=pa[31:12]==20'h40000;
    wire gpio_select=pa[31:12]==20'h40001;
    wire timer_select=pa[31:12]==20'h40002;
    wire monitor_select=MONITOR_ENABLE && pa[31:12]==20'h40003;
    wire mon_ready,mon_error; wire [31:0] mon_data;
    rv32_monitor #(.ENABLE(MONITOR_ENABLE),.CLOCK_HZ(CLOCK_HZ),.CACHE_BYTES(CACHE_BYTES),.LINE_BYTES(LINE_BYTES),.SETS(CACHE_SETS),
        .BP_ENTRIES(BP_ENTRIES),.CONFIG(HW_CONFIG),.FIRST_WAIT(FIRST_WAIT),.BEAT_GAP(BEAT_GAP)) monitor (
        .clk(clk),.rst(rst),.valid(pv && monitor_select),.write(pw),.addr(pa[11:0]),.wdata(pd),.wstrb(ps),
        .live_counts(monitor_counts),.ready(mon_ready),.error(mon_error),.rdata(mon_data));
    reg p_ready,p_error; reg [31:0] p_data;
    assign b_cmd_ready=BURST_INTERFACE && !rst && !active && (!memory_command || mc_ready);
    assign b_rsp_valid=BURST_INTERFACE && !rst && active && (to_memory?mr_valid:periph_done);
    assign b_rsp_data=to_memory?mr_data:saved_rdata;
    assign b_rsp_error=to_memory?mr_error:saved_error;
    assign b_rsp_last=to_memory?mr_last:1'b1;
    always @(posedge clk) begin
        if(rst) begin active<=0; to_memory<=0; periph_done<=0; saved_write<=0; saved_error<=0; saved_address<=0; saved_wdata<=0; saved_rdata<=0; saved_strobes<=0; end
        else if(BURST_INTERFACE) begin
            if(b_cmd_valid && b_cmd_ready) begin
                active<=1; to_memory<=memory_command; periph_done<=0;
                saved_write<=b_cmd_write; saved_address<=b_cmd_addr; saved_wdata<=b_cmd_wdata; saved_strobes<=b_cmd_wstrb;
            end
            if(pv && p_ready) begin periph_done<=1; saved_error<=p_error; saved_rdata<=p_data; end
            if(b_rsp_valid && b_rsp_ready && b_rsp_last) active<=0;
        end
    end
    wire mr,me,ur,ue,gr,ge,tr,te;
    wire [31:0] md,ud,gd,td;
    rv32_soc_memory #(.BURST_INTERFACE(BURST_INTERFACE),.FIRST_WAIT(FIRST_WAIT),.BEAT_GAP(BEAT_GAP),.ROM_BYTES(ROM_BYTES),.RAM_BYTES(RAM_BYTES),.ROM_FILE(ROM_FILE)) memory (
        .clk(clk),.rst(rst),.iv(iv),.ia(ia),.ir(ir),.idata(idata),.ie(ie),
        .dv(!BURST_INTERFACE && dv && mem_select),.dw(dw),.da(da),.wd(wd),.ws(ws),.dr(mr),.rdata(md),.de(me),
        .b_cmd_valid(BURST_INTERFACE && !active && b_cmd_valid && memory_command),.b_cmd_ready(mc_ready),
        .b_cmd_write(b_cmd_write),.b_cmd_instr(b_cmd_instr),.b_cmd_addr(b_cmd_addr),.b_cmd_wdata(b_cmd_wdata),.b_cmd_wstrb(b_cmd_wstrb),.b_cmd_len(b_cmd_len),
        .b_rsp_valid(mr_valid),.b_rsp_ready(active && to_memory && b_rsp_ready),.b_rsp_data(mr_data),.b_rsp_error(mr_error),.b_rsp_last(mr_last)
    );
    rv32_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart (
        .clk(clk),.rst(rst),.valid(pv && uart_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(ur),.rdata(ud),.error(ue),.rx(uart_rx),.tx(uart_tx)
    );
    rv32_gpio gpio (
        .clk(clk),.rst(rst),.valid(pv && gpio_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(gr),.rdata(gd),.error(ge),
        .pins_in(gpio_in),.pins_out(gpio_out),.pins_oe(gpio_oe)
    );
    rv32_timer timer (
        .clk(clk),.rst(rst),.valid(pv && timer_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(tr),.rdata(td),.error(te),.pending(timer_pending)
    );
    always @* begin
        p_ready=pv; p_data=0; p_error=pv;
        if(!BURST_INTERFACE && mem_select) begin p_ready=mr; p_data=md; p_error=me; end
        else if(uart_select) begin p_ready=ur; p_data=ud; p_error=ue; end
        else if(gpio_select) begin p_ready=gr; p_data=gd; p_error=ge; end
        else if(timer_select) begin p_ready=tr; p_data=td; p_error=te; end
        else if(monitor_select) begin p_ready=mon_ready; p_data=mon_data; p_error=mon_error; end
        dr=BURST_INTERFACE?1'b0:p_ready; rdata=p_data; de=p_error;
    end
endmodule

`timescale 1ns/1ps
// Polling timer. pending is reserved for a future interrupt connection.
// Count writes require a stopped counter. No implicit CSR or CLINT semantics.
module rv32_timer (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire ready,
    output reg [31:0] rdata,
    output reg error,
    output wire pending
);
    reg [63:0] count, compare;
    reg enable, compare_enable;
    wire [31:0] mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    assign ready = valid;
    assign pending = compare_enable && count >= compare;
    always @* begin
        rdata = 0; error = 0;
        case (addr[11:2])
            10'h000: begin rdata = count[31:0]; error = write && enable; end
            10'h001: begin rdata = count[63:32]; error = write && enable; end
            10'h002: rdata = compare[31:0];
            10'h003: rdata = compare[63:32];
            10'h004: rdata = {30'b0,compare_enable,enable};
            10'h005: begin rdata = {31'b0,pending}; error = write; end
            default: error = 1;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            count <= 0; compare <= 64'hffffffffffffffff;
            enable <= 0; compare_enable <= 0;
        end else begin
            if (enable) count <= count + 1;
            if (valid && ready && write && !error) begin
                case (addr[11:2])
                    10'h000: count[31:0] <= (count[31:0] & ~mask) | (wdata & mask);
                    10'h001: count[63:32] <= (count[63:32] & ~mask) | (wdata & mask);
                    10'h002: compare[31:0] <= (compare[31:0] & ~mask) | (wdata & mask);
                    10'h003: compare[63:32] <= (compare[63:32] & ~mask) | (wdata & mask);
                    10'h004: if (wstrb[0]) begin
                        enable <= wdata[0]; compare_enable <= wdata[1];
                    end
                endcase
            end
        end
    end
endmodule

`timescale 1ns/1ps
// 8 data bits, no parity, one stop bit. One TX frame + 4-byte RX FIFO.
// MMIO DATA writes wait for idle TX; reads wait for an available RX byte.
module rv32_uart #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output reg ready,
    output reg [31:0] rdata,
    output reg error,
    input wire rx,
    output reg tx
);
    localparam integer INITIAL_DIV = (CLOCK_HZ + BAUD/2)/BAUD;
    reg [15:0] divisor;
    wire [31:0] byte_mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    wire [31:0] merged_div = ({16'b0,divisor} & ~byte_mask) | (wdata & byte_mask);
    reg tx_busy;
    reg [15:0] tx_div, tx_count;
    reg [9:0] tx_frame;
    reg [3:0] tx_bit;
    reg rx_meta /* synthesis syn_preserve=1 */;
    reg rx_sync /* synthesis syn_preserve=1 */;
    localparam RX_IDLE=0, RX_START=1, RX_DATA=2, RX_STOP=3, RX_RECOVER=4;
    reg [2:0] rx_state;
    reg [15:0] rx_div, rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift, received;
    reg receive_pulse, frame_error_pulse;
    reg [7:0] fifo [0:3];
    reg [1:0] read_ptr, write_ptr;
    reg [2:0] fifo_count;
    reg overrun, frame_error;
    wire data_reg = addr[11:2] == 0;
    wire status_reg = addr[11:2] == 1;
    wire fire = valid && ready && !error;
    wire pop = fire && data_reg && !write;
    wire push = receive_pulse && (fifo_count < 4 || pop);

    always @* begin
        ready = valid; rdata = 0; error = 0;
        case (addr[11:2])
            10'h000: begin
                rdata = fifo_count != 0 ? {24'b0,fifo[read_ptr]} : 0;
                if (addr[1:0] != 0 || (write && !wstrb[0])) error = 1;
                else ready = valid && (write ? !tx_busy : fifo_count != 0);
            end
            10'h001: rdata = {27'b0,(rx_state != RX_IDLE),frame_error,overrun,(fifo_count != 0),!tx_busy};
            10'h002: begin
                rdata = {16'b0,divisor};
                if (write && (merged_div < 8 || merged_div > 65535)) error = 1;
            end
            10'h003: begin rdata = {29'b0,fifo_count}; error = write; end
            default: error = 1;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            divisor <= INITIAL_DIV;
            tx <= 1; tx_busy <= 0; tx_div <= INITIAL_DIV;
            tx_count <= 0; tx_frame <= 10'h3ff; tx_bit <= 0;
        end else begin
            if (fire && write && addr[11:2] == 2) divisor <= merged_div[15:0];
            if (tx_busy) begin
                if (tx_count == 0) begin
                    if (tx_bit == 9) begin tx_busy <= 0; tx <= 1; end
                    else begin
                        tx_bit <= tx_bit + 1;
                        tx <= tx_frame[tx_bit + 1];
                        tx_count <= tx_div - 1;
                    end
                end else tx_count <= tx_count - 1;
            end else if (fire && data_reg && write) begin
                tx_frame <= {1'b1,wdata[7:0],1'b0};
                tx_div <= divisor; tx_count <= divisor - 1;
                tx_bit <= 0; tx_busy <= 1; tx <= 0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1; rx_sync <= 1; rx_state <= RX_IDLE;
            rx_div <= INITIAL_DIV; rx_count <= 0; rx_bit <= 0;
            rx_shift <= 0; received <= 0; receive_pulse <= 0; frame_error_pulse <= 0;
        end else begin
            rx_meta <= rx; rx_sync <= rx_meta;
            receive_pulse <= 0; frame_error_pulse <= 0;
            case (rx_state)
                RX_IDLE: if (!rx_sync) begin
                    rx_div <= divisor; rx_count <= (divisor >> 1) - 1; rx_state <= RX_START;
                end
                RX_START: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else if (rx_sync) rx_state <= RX_IDLE; // reject a short low glitch
                    else begin rx_state <= RX_DATA; rx_bit <= 0; rx_count <= rx_div - 1; end
                end
                RX_DATA: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else begin
                        rx_shift[rx_bit] <= rx_sync; rx_count <= rx_div - 1;
                        if (rx_bit == 7) rx_state <= RX_STOP;
                        else rx_bit <= rx_bit + 1;
                    end
                end
                RX_STOP: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else if (rx_sync) begin
                        received <= rx_shift; receive_pulse <= 1; rx_state <= RX_IDLE;
                    end else begin frame_error_pulse <= 1; rx_state <= RX_RECOVER; end
                end
                RX_RECOVER: if (rx_sync) rx_state <= RX_IDLE;
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            read_ptr <= 0; write_ptr <= 0; fifo_count <= 0;
            overrun <= 0; frame_error <= 0;
        end else begin
            if (fire && write && status_reg && wstrb[0]) begin
                if (wdata[2]) overrun <= 0;
                if (wdata[3]) frame_error <= 0;
            end
            // A newly observed error wins over a simultaneous software clear.
            if (receive_pulse && !push) overrun <= 1;
            if (frame_error_pulse) frame_error <= 1;
            if (push) begin fifo[write_ptr] <= received; write_ptr <= write_ptr + 1; end
            if (pop) read_ptr <= read_ptr + 1;
            case ({push,pop})
                2'b10: fifo_count <= fifo_count + 1;
                2'b01: fifo_count <= fifo_count - 1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule

module rv32_soc_memory #(
    parameter integer BURST_INTERFACE=0, FIRST_WAIT=0, BEAT_GAP=0,
    parameter integer ROM_BYTES = 32768,
    parameter integer RAM_BYTES = 32768,
    parameter [31:0] RAM_BASE = 32'h20000000,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire clk, rst,
    input wire iv,
    input wire [31:0] ia,
    output wire ir,
    output wire [31:0] idata,
    output wire ie,
    input wire dv, dw,
    input wire [31:0] da, wd,
    input wire [3:0] ws,
    output wire dr,
    output wire [31:0] rdata,
    output wire de,
    input wire b_cmd_valid,b_cmd_write,b_cmd_instr,
    input wire [31:0] b_cmd_addr,b_cmd_wdata,
    input wire [3:0] b_cmd_wstrb,
    input wire [7:0] b_cmd_len,
    output wire b_cmd_ready,
    output wire b_rsp_valid,b_rsp_error,b_rsp_last,
    output wire [31:0] b_rsp_data,
    input wire b_rsp_ready
);

    localparam IDLE=0, WAIT_STATE=1, RESPONSE=2;
    reg [1:0] state;
    reg [31:0] address, write_data;
    reg [3:0] strobes;
    reg [7:0] length, beat;
    reg write_op, instruction, command_bad, beat_error, rom_selected, ram_selected;
    integer delay_count;
    wire accept = b_cmd_valid && b_cmd_ready;
    wire advance = b_rsp_valid && b_rsp_ready && !b_rsp_last;
    wire [31:0] load_address = accept ? b_cmd_addr : address + 32'd4;
    wire [31:0] memory_address = accept || advance ? load_address : address;
    wire load_write = accept ? b_cmd_write : write_op;
    wire load_instruction = accept ? b_cmd_instr : instruction;
    wire [32:0] command_end = {1'b0,b_cmd_addr} + ({25'b0,b_cmd_len} << 2);
    wire bad_command = (b_cmd_write && b_cmd_len != 0) ||
                       (b_cmd_len != 0 && b_cmd_addr[1:0] != 0) || command_end[32];
    wire load_bad = accept ? bad_command : command_bad;
    wire load_rom = load_address < ROM_BYTES;
    wire load_ram = load_address >= RAM_BASE && load_address < RAM_BASE + RAM_BYTES;
    wire legal = load_instruction ? (load_rom && !load_write && load_address[1:0] == 0) :
                                   ((load_rom && !load_write) || load_ram);
    wire [31:0] rom_data, ram_data;
    wire ram_write = !rst && b_rsp_valid && b_rsp_ready && write_op && !beat_error && ram_selected;

    assign ir = 0;
    assign idata = 0;
    assign ie = 0;
    assign dr = 0;
    assign rdata = 0;
    assign de = 0;
    assign b_cmd_ready = !rst && state == IDLE;
    assign b_rsp_valid = !rst && state == RESPONSE;
    assign b_rsp_error = beat_error;
    assign b_rsp_last = beat == length;
    assign b_rsp_data = beat_error || write_op ? 32'b0 :
                        rom_selected ? rom_data : ram_selected ? ram_data : 32'b0;

    pango_evolve_rom rom (
        .clk(clk), .rst(rst), .addr(memory_address[14:2]),
        .addr_strobe(1'b0), .rd_data(rom_data)
    );
    pango_evolve_ram ram (
        .a_clk(clk), .a_rst(rst), .a_addr(memory_address[14:2]), .a_wr_en(ram_write),
        .a_wr_byte_en(strobes), .a_wr_data(write_data), .a_rd_data(ram_data),
        .b_clk(clk), .b_rst(rst), .b_addr(13'b0), .b_wr_en(1'b0),
        .b_wr_byte_en(4'b0), .b_wr_data(32'b0), .b_rd_data()
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            address <= 0; write_data <= 0; strobes <= 0; length <= 0; beat <= 0;
            write_op <= 0; instruction <= 0; command_bad <= 0;
            beat_error <= 0; rom_selected <= 0; ram_selected <= 0; delay_count <= 0;
        end else begin
            if (accept || advance) begin
                beat_error <= load_bad || !legal;
                rom_selected <= load_rom;
                ram_selected <= load_ram;
            end
            if (accept) begin
                address <= b_cmd_addr; write_data <= b_cmd_wdata; strobes <= b_cmd_wstrb;
                length <= b_cmd_len; beat <= 0; write_op <= b_cmd_write;
                instruction <= b_cmd_instr; command_bad <= bad_command;
                delay_count <= FIRST_WAIT;
                state <= FIRST_WAIT == 0 ? RESPONSE : WAIT_STATE;
            end else if (state == WAIT_STATE) begin
                if (delay_count <= 1) state <= RESPONSE;
                else delay_count <= delay_count - 1;
            end else if (b_rsp_valid && b_rsp_ready) begin
                if (b_rsp_last) state <= IDLE;
                else begin
                    address <= address + 32'd4;
                    beat <= beat + 1'b1;
                    delay_count <= BEAT_GAP;
                    state <= BEAT_GAP == 0 ? RESPONSE : WAIT_STATE;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (!BURST_INTERFACE || ROM_BYTES != 32768 || RAM_BYTES != 32768 || RAM_BASE != 32'h20000000)
            $fatal(1, "EVOLVE5 FPGA adapter requires the 32 KiB burst memory configuration");
    end
`endif
endmodule

module board_top #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer RESET_HOLD_CYCLES = 250000
) (
    input wire sys_clk,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1
);
    wire rst_n;
    wire halted;
    wire debug_trap;
    wire [7:0] gpio_out;
    reg trap_seen;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk), .key0_n(key0_n), .rst_n(rst_n)
    );
    rv32_soc #(
        .CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD_RATE), .M_ENABLE(1),
        .BP_INDEX_BITS(5), .FETCH_DEPTH(4), .FETCH_BYPASS(1), .LOAD_FORWARD(1),
        .DUAL_ENABLE(1), .WIDE_FETCH(1), .PAIR_BRANCH(1), .PAIR_MEMORY(1),
        .PAIR_JALR(1), .FAST_STORE(1), .FAST_MUL(1), .PAIR_MUL(1),
        .ICACHE_ENABLE(1), .DCACHE_ENABLE(1), .CACHE_SET_BITS(5),
        .CACHE_LINE_WORD_BITS(2), .BURST_BACKEND(1), .BURST_FILL(1)
    ) u_soc (
        .clk(sys_clk), .rst(!rst_n), .uart_rx(1'b1), .uart_tx(uart_tx),
        .gpio_in(8'b0), .gpio_out(gpio_out), .gpio_oe(), .timer_pending(),
        .halted(halted), .trap_pc(), .trap_cause(), .trap_tval(),
        .debug_commit(), .debug_trap(debug_trap), .debug_pc(), .debug_insn()
    );
    always @(posedge sys_clk) begin
        if (!rst_n)
            trap_seen <= 0;
        else if (debug_trap || halted)
            trap_seen <= 1;
    end
    assign led0 = rst_n && gpio_out[0];
    assign led1 = rst_n && (gpio_out[1] || trap_seen);
endmodule

module board_reset #(
    parameter integer HOLD_CYCLES = 250000
) (
    input wire clk,
    input wire key0_n,
    output wire rst_n
);
    reg [1:0] release_sync = 2'b00 /* synthesis syn_preserve=1 */;
    reg [31:0] release_count = 32'b0;
    reg hold_reset = 1'b1;

    always @(posedge clk or negedge key0_n) begin
        if (!key0_n)
            release_sync <= 2'b00;
        else
            release_sync <= {release_sync[0], 1'b1};
    end

    always @(posedge clk) begin
        if (!release_sync[1]) begin
            release_count <= 32'b0;
            hold_reset <= 1'b1;
        end
        else if (hold_reset) begin
            if (release_count >= HOLD_CYCLES - 1)
                hold_reset <= 1'b0;
            else
                release_count <= release_count + 32'd1;
        end
    end

    assign rst_n = release_sync[1] && !hold_reset;
endmodule
