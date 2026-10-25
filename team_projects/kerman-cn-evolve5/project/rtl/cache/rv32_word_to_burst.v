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
