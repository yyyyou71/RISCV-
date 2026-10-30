`default_nettype none
// Vendor-only 128x512 asynchronous FIFO, standard one-cycle read plus prefetch.
module video_async_fifo #(
    parameter integer WIDTH=128, ADDR_BITS=9
)(
    input wire wr_clk,wr_reset_n,wr_en,
    input wire [WIDTH-1:0] wr_data,
    output wire full,
    input wire rd_clk,rd_reset_n,rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire empty,
    output wire [ADDR_BITS:0] rd_level
);
    wire ip_empty, ip_rd_en, almost_full, almost_empty;
    wire [ADDR_BITS:0] ip_rd_level,ip_wr_level;
    reg head_valid;
    assign ip_rd_en=rd_reset_n && !ip_empty && (!head_valid || rd_en);
    assign empty=!head_valid;
    assign rd_level=ip_rd_level+{{ADDR_BITS{1'b0}},head_valid};
    always @(posedge rd_clk or negedge rd_reset_n)
        if(!rd_reset_n) head_valid<=0;
        else if(ip_rd_en) head_valid<=1;
        else if(rd_en) head_valid<=0;
    video_fifo_ip u_ip (
        .wr_clk(wr_clk),.wr_rst(!wr_reset_n),.wr_en(wr_en && !full && wr_reset_n),.wr_data(wr_data),
        .wr_full(full),.almost_full(almost_full),.wr_water_level(ip_wr_level),
        .rd_clk(rd_clk),.rd_rst(!rd_reset_n),.rd_en(ip_rd_en),.rd_data(rd_data),
        .rd_empty(ip_empty),.almost_empty(almost_empty),.rd_water_level(ip_rd_level)
    );
    wire unused_flags=^{almost_full,almost_empty,ip_wr_level};
    // synthesis translate_off
    initial if(WIDTH!=128 || ADDR_BITS!=9) $fatal(1,"video_fifo_ip must be 128x512");
    // synthesis translate_on
endmodule
`default_nettype wire
