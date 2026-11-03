`timescale 1ns/1ps
// Short integration: actual shared-DDR arbiters, DDR behavior model, raw writer,
// box overlay, and PCIe-facing async FIFO. Small RAW geometry limits run time.
module TB_spi_image_pcie;
    reg clk=0,pcie_clk=0,rst_n=0;always #20 clk=~clk;always #5 pcie_clk=~pcie_clk;
    wire core_clk,ready,shared_fault;
    reg we=0;reg [7:0] wa=0,ra=4;reg [31:0] wd=0;wire [31:0] rd;
    wire image_active,image_held,image_available,image_fault;wire [31:0] image_id;
    wire [27:0] image_awaddr,image_araddr;wire image_awvalid,image_arvalid,image_awap,image_arap;
    wire [3:0] image_awlen,image_arlen,image_awid,image_arid,image_wid,image_rid;
    wire [127:0] image_wdata,image_rdata;wire [15:0] image_wstrb;
    wire image_awready,image_arready,image_wready,image_wlast,image_rvalid,image_rlast;
    wire [127:0] pixels;wire empty,read_busy,read_done;
    wire [4:0] available;wire [159:0] ids;
    reg [4:0] present_frames=0;reg [1023:0] boxes=0;reg read_enable=0;
    integer clocks=0,got=0;reg d1=0,d2=0;
    wire pop=read_enable&&!empty&&clocks%5!=0;
    spi_image_capture #(.WIDTH(128),.HEIGHT(2)) capture(
        .clk(clk),.core_clk(core_clk),.rst_n(rst_n),.ddr_ready(ready),.shared_fault(shared_fault),
        .external_hold({4'b0,read_busy}),.dev_we(we),.addr_wr(wa),.addr_rd(ra),.wdata(wd),.rdata(rd),
        .active(image_active),.held(image_held),.available(image_available),.frame_id(image_id),.fault(image_fault),
        .axi_awaddr(image_awaddr),
        .axi_araddr(image_araddr),
        .axi_awvalid(image_awvalid),
        .axi_arvalid(image_arvalid),
        .axi_awap(image_awap),
        .axi_arap(image_arap),
        .axi_awlen(image_awlen),
        .axi_arlen(image_arlen),
        .axi_awid(image_awid),
        .axi_arid(image_arid),
        .axi_awready(image_awready),
        .axi_arready(image_arready),
        .axi_wdata(image_wdata),
        .axi_wstrb(image_wstrb),
        .axi_wready(image_wready),
        .axi_wlast(image_wlast),
        .axi_wid(image_wid),
        .axi_rdata(image_rdata),
        .axi_rvalid(image_rvalid),
        .axi_rlast(image_rlast),
        .axi_rid(image_rid));
    frame_ring_ddr3 #(.SPI_IMAGE(1),.H_ACTIVE(128),.V_ACTIVE(2),.CONTROLLED_READER(1)) ring(
        .image_active(image_active),
        .image_held(image_held),
        .image_available(image_available),
        .image_fault(image_fault),
        .image_id(image_id),
        .image_awaddr(image_awaddr),
        .image_araddr(image_araddr),
        .image_awvalid(image_awvalid),
        .image_arvalid(image_arvalid),
        .image_awap(image_awap),
        .image_arap(image_arap),
        .image_awlen(image_awlen),
        .image_arlen(image_arlen),
        .image_arid(image_arid),
        .image_wdata(image_wdata),
        .image_wstrb(image_wstrb),
        .image_awready(image_awready),
        .image_arready(image_arready),
        .image_wready(image_wready),
        .image_wlast(image_wlast),
        .image_wid(image_wid),
        .image_rvalid(image_rvalid),
        .image_rlast(image_rlast),
        .image_rid(image_rid),
        .image_rdata(image_rdata),
        .present_frames(present_frames),.present_hold(5'b0),.present_box_count(5'd1),.present_boxes(boxes),
        .tensor_awaddr('0),.tensor_awvalid(1'b0),.tensor_awap(1'b0),.tensor_fault(1'b0),.tensor_awlen('0),.tensor_awid('0),
        .tensor_wdata('0),.tensor_wstrb('0),.tensor_hold('0),
        .cpu_awaddr('0),.cpu_araddr('0),.cpu_awvalid(1'b0),.cpu_arvalid(1'b0),.cpu_awap(1'b0),.cpu_arap(1'b0),
        .cpu_awlen('0),.cpu_arlen('0),.cpu_awid('0),.cpu_arid('0),.cpu_wdata('0),.cpu_wstrb('0),
        .hold_mask('0),.stream_ok(1'b1),.available(available),.frame_ids(ids),.shared_fault(shared_fault),
        .sys_clk(clk),.sys_rst_n(rst_n),.clr(1'b0),.core_clk(core_clk),.ddr_init_done(ready),
        .wr_clk(clk),.wr_data('0),.wr_en(1'b0),.vs(1'b0),.de(1'b0),
        .rd_clk(pcie_clk),.dma_start(1'b0),.rd_data(pixels),.rd_en(pop),.rd_empty(empty),.read_busy(read_busy),.read_done(read_done));
    function [23:0] pixel;input integer n;begin pixel={8'(n*17),8'(n*7),8'(n*11)};end endfunction
    integer lane,n;reg [23:0] p;reg [127:0] expected;
    always @(posedge pcie_clk)begin
        clocks<=clocks+1;d1<=pop;d2<=d1;
        if(d2)begin
            for(lane=0;lane<8;lane=lane+1)begin
                n=got*8+lane;p=pixel(n);
                expected[lane*16+:16]=(n%128>=10&&n%128<=20)?16'h07e0:{p[23:19],p[15:10],p[7:3]};
            end
            if(got>=32||pixels!==expected)$fatal(1,"PCIe-facing FIFO mismatch word=%0d got=%h expected=%h",got,pixels,expected);
            got<=got+1;
        end
        if(shared_fault||image_fault)$fatal(1,"shared DDR fault");
    end
    task write_reg;input [7:0] a;input [31:0] v;begin
        @(negedge clk);wa=a;wd=v;we=1;@(negedge clk);we=0;
    end endtask
    reg [127:0] word_data;integer i,k;
    initial begin
        repeat(10)@(negedge clk);rst_n=1;wait(ready);
        for(i=0;i<64;i=i+1)begin
            for(k=0;k<4;k=k+1)begin p=pixel(i*4+k);word_data[k*32+:32]={8'b0,p[7:0],p[15:8],p[23:16]};end
            ring.u_ddr3.store_word(28'h3f00000+i*8,word_data,16'hffff);
        end
        write_reg(8'h08,7);write_reg(8'h2c,0);write_reg(0,1);
        ra=4;#1;while(!rd[1])@(negedge clk);
        if((rd&63)!=26||available!=1||ids[31:0]!=7)$fatal(1,"retained frame metadata");
        boxes[63:0]={4'b0,16'h07e0,11'd1,11'd20,11'd0,11'd10};
        @(negedge core_clk);present_frames=1;@(negedge core_clk);present_frames=0;read_enable=1;
        wait(got==32);repeat(8)@(negedge clk);
        if(read_busy||!empty||!image_held)$fatal(1,"reader/lease did not drain");
        write_reg(0,2);ra=4;#1;while(!rd[1])@(negedge clk);
        if(image_held||available)$fatal(1,"release failed");
        $display("PASS shared DDR/PCIe integration: uploaded image -> hardware RAW storage -> top-16 overlay -> async output FIFO, 256 pixels");$finish;
    end
    initial begin #20000000;$fatal(1,"integration timeout");end
endmodule
module ddr_2_fifo(
    input wire wr_clk,wr_rst,wr_en,input wire [127:0] wr_data,
    output wire wr_full,almost_full,output wire [8:0] wr_water_level,
    input wire rd_clk,rd_rst,rd_en,output reg [127:0] rd_data,
    output wire rd_empty,almost_empty
);
    wire [127:0] q;
    pango_video_fifo_model #(.DATA_WIDTH(128),.ADDR_WIDTH(8)) model(
        .wr_clk(wr_clk),.wr_rst(wr_rst),.wr_en(wr_en),.wr_data(wr_data),.wr_full(wr_full),
        .almost_full(almost_full),.wr_water_level(wr_water_level),
        .rd_clk(rd_clk),.rd_rst(rd_rst),.rd_en(rd_en),.rd_data(q),.rd_empty(rd_empty),.almost_empty(almost_empty),.rd_water_level());
    always @(posedge rd_clk)rd_data<=q;
endmodule
