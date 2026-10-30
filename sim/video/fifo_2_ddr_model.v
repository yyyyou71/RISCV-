// Test-only packing/latency model. Real board uses the unchanged vendor async FIFO.
module fifo_2_ddr (
    input wire wr_clk,wr_rst,wr_en,
    input wire [15:0] wr_data,
    output wire wr_full,almost_full,
    input wire rd_clk,rd_rst,rd_en,
    output reg [127:0] rd_data,
    output wire rd_empty,almost_empty,
    output wire [9:0] rd_water_level
);
    reg [127:0] words[0:511],pack;
    integer wp=0,rp=0,lane=0;
    assign rd_water_level=10'(wp-rp);
    assign rd_empty=wp==rp;
    assign almost_empty=wp-rp<4;
    assign wr_full=wp-rp>=512;assign almost_full=wp-rp>=480;
    always @(posedge wr_clk)begin
        if(wr_rst)begin wp<=0;lane<=0;pack<=0;end
        else if(wr_en)begin
            if(wr_full)$fatal(1,"test FIFO overflow");
            pack[lane*16+:16]<=wr_data;
            if(lane==7)begin words[wp%512]<={wr_data,pack[111:0]};wp<=wp+1;lane<=0;end
            else lane<=lane+1;
        end
    end
    always @(posedge rd_clk)begin
        if(rd_rst)begin rp<=0;rd_data<=0;end
        else if(rd_en)begin
            if(rd_empty)$fatal(1,"test FIFO underflow");
            rd_data<=words[rp%512];rp<=rp+1;
        end
    end
endmodule
