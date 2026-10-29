`default_nettype none
// 紫光 DRM Based FIFO 的薄封装：外部为预读接口，IP内部为同步读接口。
// 开启 USE_PANGO_VIDEO_FIFO_IP 后例化 IPC 生成的 video_fifo_ip；否则使用行为模型。
// 固定上板配置：异步、128x512、ASYNC复位、不使能输出寄存/低功耗/字节写。
// 参数化小深度仅供仿真压测；真实IP不接受本行为模型的WIDTH/ADDR_BITS参数。
module video_async_fifo #(
    parameter integer WIDTH = 128,
    parameter integer ADDR_BITS = 9
)(
    input wire wr_clk, wr_reset_n,
    input wire wr_en,
    input wire [WIDTH-1:0] wr_data,
    output wire full,
    input wire rd_clk, rd_reset_n,
    input wire rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire empty,
    output wire [ADDR_BITS:0] rd_level
);
    wire ip_empty,ip_rd_en,ip_almost_full,ip_almost_empty;
    wire [ADDR_BITS:0] ip_rd_level,ip_wr_level;
    reg head_valid;
    // IP的输出寄存数据本身作为一个预读槽，背压时不再发rd_en，数据自然保持。
    // 消费旧字的同一拍可读出下一字，因此填满后可连续每拍输出一字。
    assign ip_rd_en=rd_reset_n && !ip_empty && (!head_valid || rd_en);
    assign empty=!head_valid;
    // native读水位不含已预读的字，须加回这个槽；容量至多为512+1字。
    assign rd_level=ip_rd_level+{{ADDR_BITS{1'b0}},head_valid};
    always @(posedge rd_clk or negedge rd_reset_n)
        if(!rd_reset_n) head_valid<=0;
        else if(ip_rd_en) head_valid<=1;
        else if(rd_en) head_valid<=0;

`ifdef USE_PANGO_VIDEO_FIFO_IP
    // 端口名称与ROM_RAM.pdf第七章、PDS生成模板保持一致。
    // 在IPC中启用两个Water Level端口；生成器可能省略未启用的可选端口。
    video_fifo_ip u_ip (
`else
    pango_video_fifo_model #(.DATA_WIDTH(WIDTH),.ADDR_WIDTH(ADDR_BITS)) u_ip (
`endif
        .wr_clk(wr_clk),.wr_rst(!wr_reset_n),.wr_en(wr_en && !full && wr_reset_n),.wr_data(wr_data),
        .wr_full(full),.almost_full(ip_almost_full),.wr_water_level(ip_wr_level),
        .rd_clk(rd_clk),.rd_rst(!rd_reset_n),.rd_en(ip_rd_en),.rd_data(rd_data),
        .rd_empty(ip_empty),.almost_empty(ip_almost_empty),.rd_water_level(ip_rd_level)
    );
    wire unused_flags=^{ip_almost_full,ip_almost_empty,ip_wr_level};
    // synthesis translate_off
    initial begin
        if(ADDR_BITS<4 || ADDR_BITS>19 || WIDTH<1 || WIDTH>1152)
            $fatal(1,"video_async_fifo: unsupported configuration");
`ifdef USE_PANGO_VIDEO_FIFO_IP
        if(WIDTH!=128 || ADDR_BITS!=9)
            $fatal(1,"video_fifo_ip must be generated as 128x512");
`endif
    end
    // synthesis translate_on
endmodule
`default_nettype wire
