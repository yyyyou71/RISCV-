`default_nettype none
// 仅用于验证USE_PANGO_VIDEO_FIFO_IP分支的端口绑定；不是厂商IP仿真库。
// 上板不要加入此文件，改用IPC生成的同名video_fifo_ip。
module video_fifo_ip (
    input wire wr_clk,wr_rst,wr_en,
    input wire [127:0] wr_data,
    output wire wr_full,almost_full,
    output wire [9:0] wr_water_level,
    input wire rd_clk,rd_rst,rd_en,
    output wire [127:0] rd_data,
    output wire rd_empty,almost_empty,
    output wire [9:0] rd_water_level
);
    pango_video_fifo_model u_model (
        .wr_clk(wr_clk),.wr_rst(wr_rst),.wr_en(wr_en),.wr_data(wr_data),.wr_full(wr_full),
        .almost_full(almost_full),.wr_water_level(wr_water_level),.rd_clk(rd_clk),.rd_rst(rd_rst),.rd_en(rd_en),
        .rd_data(rd_data),.rd_empty(rd_empty),.almost_empty(almost_empty),.rd_water_level(rd_water_level)
    );
endmodule
`default_nettype wire
