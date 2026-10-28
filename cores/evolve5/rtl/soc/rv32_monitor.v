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
