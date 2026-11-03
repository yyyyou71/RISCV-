// Test-only vendor FIFO model: registered read, no optional output register.
module spi_tensor_fifo(
    input wire wr_clk,wr_rst,wr_en,input wire [127:0] wr_data,
    output wire wr_full,almost_full,
    input wire rd_clk,rd_rst,rd_en,output reg [127:0] rd_data,
    output wire rd_empty,almost_empty,output wire [8:0] rd_water_level
);
    reg [127:0] words[0:255];integer wp=0,rp=0;
    assign wr_full=wp-rp>=256;assign almost_full=wp-rp>=240;
    assign rd_empty=wp==rp;assign almost_empty=wp-rp<16;
    assign rd_water_level=9'(wp-rp);
    always @(posedge wr_clk)
        if(wr_rst)wp<=0;else if(wr_en)begin
            if(wr_full)$fatal(1,"tensor FIFO overflow");words[wp%256]<=wr_data;wp<=wp+1;
        end
    always @(posedge rd_clk)
        if(rd_rst)begin rp<=0;rd_data<=0;end else if(rd_en)begin
            if(rd_empty)$fatal(1,"tensor FIFO underflow");rd_data<=words[rp%256];rp<=rp+1;
        end
endmodule
