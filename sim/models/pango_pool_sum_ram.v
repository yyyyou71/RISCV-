`default_nettype none
// Test-only model: uninitialized storage, one-cycle synchronous read.
// Never add this file to PDS. Same address/clock interface as the vendor IP.
module pango_pool_sum_ram (
    input wire wr_clk,wr_rst,wr_en,
    input wire [8:0] wr_addr,
    input wire [47:0] wr_data,
    input wire rd_clk,rd_clk_en,rd_rst,
    input wire [8:0] rd_addr,
    output reg [47:0] rd_data
);
    reg [47:0] words[0:511];
    always @(posedge wr_clk)if(!wr_rst&&wr_en)words[wr_addr]<=wr_data;
    always @(posedge rd_clk)if(rd_rst)rd_data<=0;else if(rd_clk_en)rd_data<=words[rd_addr];
endmodule
`default_nettype wire
