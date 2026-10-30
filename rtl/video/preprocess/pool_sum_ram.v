`default_nettype none
// 96 RGB accumulators in one vendor simple dual-port RAM, synchronous read.
// No RAM clear is required: the first input row of a bin ignores old contents.
module pool_sum_ram (
    input wire clk,rst_n,wr_en,
    input wire [6:0] wr_addr,rd_addr,
    input wire [47:0] wr_data,
    output wire [47:0] rd_data
);
    pango_pool_sum_ram u_ip (
        .wr_clk(clk),.wr_rst(!rst_n),.wr_en(wr_en),.wr_addr({2'b0,wr_addr}),
        .wr_data(wr_data),
        .rd_clk(clk),.rd_clk_en(1'b1),.rd_rst(!rst_n),.rd_addr({2'b0,rd_addr}),.rd_data(rd_data)
    );
endmodule
`default_nettype wire
