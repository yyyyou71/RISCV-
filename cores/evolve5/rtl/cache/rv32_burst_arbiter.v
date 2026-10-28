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
