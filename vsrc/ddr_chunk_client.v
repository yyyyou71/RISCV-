`timescale 1ns/1ps
`default_nettype none
// 将 16/32 字节原子请求适配到 ddr_block_transfer；一个请求在途。
module ddr_chunk_client (
    input wire clk, rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write, req_two,
    input wire [31:0] req_addr,
    input wire [255:0] req_data,
    output wire rsp_valid, input wire rsp_ready,
    output reg [255:0] rsp_data,
    output reg rsp_error,
    output reg [3:0] rsp_code,
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
    localparam [1:0] IDLE=0, COMMAND=1, TRANSFER=2, RESPONSE=3;
    reg [1:0] state;
    reg direction, two;
    reg [31:0] address_reg;
    reg [255:0] payload;
    reg [1:0] write_index, read_index;
    assign req_ready=rst_n && state==IDLE && !dma_fault;
    assign rsp_valid=rst_n && state==RESPONSE;
    assign dma_cmd_valid=rst_n && state==COMMAND;
    assign dma_cmd_write=direction;
    assign dma_cmd_addr=address_reg;
    assign dma_cmd_len=two ? 32'd32 : 32'd16;
    assign dma_wr_valid=rst_n && state==TRANSFER && direction && write_index<(two ? 2:1);
    assign dma_wr_data=payload[write_index[0]*128 +: 128];
    assign dma_rd_ready=rst_n && state==TRANSFER && !direction;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; direction<=0; two<=0; address_reg<=0; payload<=0;
            write_index<=0; read_index<=0; rsp_data<=0; rsp_error<=0; rsp_code<=0;
        end else case(state)
            IDLE: if(req_valid && req_ready) begin
                direction<=req_write; two<=req_two; address_reg<=req_addr; payload<=req_data;
                write_index<=0; read_index<=0; rsp_data<=0; rsp_error<=0; rsp_code<=0;
                state<=COMMAND;
            end
            COMMAND: if(!dma_initialized) begin
                rsp_error<=1; rsp_code<=7; state<=RESPONSE;
            end else if(dma_cmd_valid && dma_cmd_ready) state<=TRANSFER;
            TRANSFER: begin
                if(dma_wr_valid && dma_wr_ready) write_index<=write_index+1'b1;
                if(dma_rd_valid && dma_rd_ready) begin
                    rsp_data[read_index[0]*128 +: 128]<=dma_rd_data;
                    read_index<=read_index+1'b1;
                end
                if(dma_done || dma_error) begin
                    rsp_error<=dma_error; rsp_code<=dma_error_code; state<=RESPONSE;
                end
            end
            RESPONSE: if(rsp_valid && rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
