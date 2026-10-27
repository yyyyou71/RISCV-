`default_nettype none
// ROM_RAM.pdf (UG021002)第七章的选定配置行为模型，不是完整FIFO IP实现。
// 仅支持同位宽异步FIFO、ASYNC高有效复位、关闭OUTPUT_REG/FAB_REG/字节写/低功耗。
// rd_en && !rd_empty时，在该读时钟沿后更新rd_data；其它时间保持，不提供FWFT。
// 写对读域状态、读对写域状态通过两级同步+本域状态寄存，通常延迟3个目的时钟。
// 数字仿真不模拟亚稳态，因此不能复现手册所述可能多延迟1拍的硬件现象。
// 两侧须共同复位。禁止在full时写、empty时读；上层封装负责门控。
module pango_video_fifo_model #(
    parameter integer DATA_WIDTH=128,
    parameter integer ADDR_WIDTH=9,
    parameter integer ALMOST_FULL_NUM=(1<<ADDR_WIDTH)-16,
    parameter integer ALMOST_EMPTY_NUM=4
)(
    input wire wr_clk,wr_rst,wr_en,
    input wire [DATA_WIDTH-1:0] wr_data,
    output reg wr_full,
    output wire almost_full,
    output reg [ADDR_WIDTH:0] wr_water_level,
    input wire rd_clk,rd_rst,rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,
    output reg rd_empty,
    output wire almost_empty,
    output reg [ADDR_WIDTH:0] rd_water_level
);
    localparam integer PTR_WIDTH=ADDR_WIDTH+1;
    localparam [PTR_WIDTH-1:0] FULL_MASK=(1<<ADDR_WIDTH)|(1<<(ADDR_WIDTH-1));
    localparam [PTR_WIDTH-1:0] FULL_LEVEL=PTR_WIDTH'(ALMOST_FULL_NUM),EMPTY_LEVEL=PTR_WIDTH'(ALMOST_EMPTY_NUM);
    reg [DATA_WIDTH-1:0] memory [0:(1<<ADDR_WIDTH)-1];
    reg [PTR_WIDTH-1:0] wr_bin,wr_gray,rd_bin,rd_gray;
    (* ASYNC_REG="TRUE" *) reg [PTR_WIDTH-1:0] rd_meta,rd_sync,wr_meta,wr_sync;
    wire [PTR_WIDTH-1:0] wr_next=wr_bin+{{ADDR_WIDTH{1'b0}},(wr_en && !wr_full)};
    wire [PTR_WIDTH-1:0] rd_next=rd_bin+{{ADDR_WIDTH{1'b0}},(rd_en && !rd_empty)};
    wire [PTR_WIDTH-1:0] wr_next_gray=(wr_next>>1)^wr_next,rd_next_gray=(rd_next>>1)^rd_next;
    function [PTR_WIDTH-1:0] gray_to_bin;
        input [PTR_WIDTH-1:0] gray;
        integer n;
        begin
            gray_to_bin[PTR_WIDTH-1]=gray[PTR_WIDTH-1];
            for(n=PTR_WIDTH-2;n>=0;n=n-1)gray_to_bin[n]=gray_to_bin[n+1]^gray[n];
        end
    endfunction
    assign almost_full=wr_water_level>=FULL_LEVEL;
    assign almost_empty=rd_water_level<=EMPTY_LEVEL;
    always @(posedge wr_clk) if(wr_en && !wr_full && !wr_rst) memory[wr_bin[ADDR_WIDTH-1:0]]<=wr_data;
    always @(posedge rd_clk) if(rd_en && !rd_empty && !rd_rst) rd_data<=memory[rd_bin[ADDR_WIDTH-1:0]];
    always @(posedge wr_clk or posedge wr_rst) begin
        if(wr_rst) begin wr_bin<=0;wr_gray<=0;rd_meta<=0;rd_sync<=0;wr_full<=0;wr_water_level<=0;end
        else begin
            rd_meta<=rd_gray;rd_sync<=rd_meta;
            wr_bin<=wr_next;wr_gray<=wr_next_gray;
            wr_full<=wr_next_gray==(rd_sync^FULL_MASK);
            wr_water_level<=wr_next-gray_to_bin(rd_sync);
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if(rd_rst) begin rd_bin<=0;rd_gray<=0;wr_meta<=0;wr_sync<=0;rd_empty<=1;rd_water_level<=0;end
        else begin
            wr_meta<=wr_gray;wr_sync<=wr_meta;
            rd_bin<=rd_next;rd_gray<=rd_next_gray;
            rd_empty<=rd_next_gray==wr_sync;
            rd_water_level<=gray_to_bin(wr_sync)-rd_next;
        end
    end
endmodule
`default_nettype wire
