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
