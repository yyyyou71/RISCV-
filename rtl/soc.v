module soc #(
    parameter integer CLK_FREQ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer ENABLE_DUAL = 0,
    parameter integer ENABLE_FSPI = 0,
    parameter integer ENABLE_DDR = 0,
    parameter integer ENABLE_AI = 0,
    parameter integer AI_ACT_WIDTH = 16,
    parameter integer DDR_TIMEOUT_CYCLES = 4096,
    parameter integer ENABLE_VIDEO = 0,
    parameter integer VIDEO_FIFO_ADDR_BITS = 9,
    parameter integer ENABLE_FRAME_CONTROL = 0,
    parameter integer ENABLE_PREPROCESS = 0,
    parameter [31:0] DDR_LIMIT_BYTES = 32'h20000000
) (
    output wire tensor_we,
    output wire [8:0] tensor_addr_wr,tensor_addr_rd,
    output wire [31:0] tensor_wdata,
    input wire [31:0] tensor_rdata,
    input wire clk,
    input wire rst_n,
    input wire spi_clk, spi_cs,
    inout wire [3:0] spi_data,
    input wire timer_irq,
    input wire core_clk, ddr_init_done,
    input wire [4:0] frame_available,
    input wire [159:0] frame_ids,
    input wire [2:0] frame_wr_slot,
    input wire frame_wr_active,shared_ddr_fault,
    input wire [31:0] video_shape,video_period,
    output wire [4:0] frame_hold_mask,
    input wire pixclk_in, vs_in, hs_in, de_in,
    input wire [7:0] r_in, g_in, b_in,
    output wire [27:0] axi_awaddr, axi_araddr,
    output wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid,
    output wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen,
    input wire axi_awready, axi_arready, axi_wready, axi_wusero_last,
    input wire [3:0] axi_wusero_id, axi_rid,
    output wire [127:0] axi_wdata,
    output wire [15:0] axi_wstrb,
    input wire [127:0] axi_rdata,
    input wire axi_rlast, axi_rvalid,
    output wire uart_txd,
    output wire bus_err,
    output wire [1:0] gpio_out
);
    wire dev_we;
    wire dev_re;
    wire [31:0] dev_addr_wr;
    wire [31:0] dev_addr_rd;
    wire [31:0] dev_wdata;
    wire [31:0] dev_rdata;
    wire [1:0] dev_size;

    Acore #(.ENABLE_DUAL(ENABLE_DUAL)) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .timer_irq(timer_irq),
        .dev_we(dev_we),
        .dev_re(dev_re),
        .bus_err(bus_err),
        .dev_addr_wr(dev_addr_wr),
        .dev_addr_rd(dev_addr_rd),
        .dev_wdata(dev_wdata),
        .dev_size(dev_size),
        .dev_rdata(dev_rdata)
    );

    peripheral_bus #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE), .ENABLE_FSPI(ENABLE_FSPI),
        .ENABLE_DDR(ENABLE_DDR), .ENABLE_AI(ENABLE_AI), .AI_ACT_WIDTH(AI_ACT_WIDTH),
        .DDR_TIMEOUT_CYCLES(DDR_TIMEOUT_CYCLES), .ENABLE_VIDEO(ENABLE_VIDEO),
        .VIDEO_FIFO_ADDR_BITS(VIDEO_FIFO_ADDR_BITS),
        .ENABLE_FRAME_CONTROL(ENABLE_FRAME_CONTROL),.ENABLE_PREPROCESS(ENABLE_PREPROCESS),.DDR_LIMIT_BYTES(DDR_LIMIT_BYTES)
    ) u_peripheral_bus (
        .clk(clk),
        .tensor_we(tensor_we),.tensor_addr_wr(tensor_addr_wr),.tensor_addr_rd(tensor_addr_rd),
        .tensor_wdata(tensor_wdata),.tensor_rdata(tensor_rdata),
        .rst_n(rst_n),
        .dev_we(dev_we),
        .dev_re(dev_re),
        .dev_addr_wr(dev_addr_wr),
        .dev_addr_rd(dev_addr_rd),
        .dev_wdata(dev_wdata),
        .dev_size(dev_size),
        .dev_rdata(dev_rdata),
        .spi_clk(spi_clk), .spi_cs(spi_cs), .spi_data(spi_data),
        .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .frame_available(frame_available),.frame_ids(frame_ids),.frame_wr_slot(frame_wr_slot),
        .frame_wr_active(frame_wr_active),.shared_ddr_fault(shared_ddr_fault),
        .video_shape(video_shape),.video_period(video_period),.frame_hold_mask(frame_hold_mask),
        .pixclk_in(pixclk_in), .vs_in(vs_in), .de_in(de_in), .rgb_in({r_in,g_in,b_in}),
        .axi_awaddr(axi_awaddr), .axi_araddr(axi_araddr),
        .axi_awuser_ap(axi_awuser_ap), .axi_aruser_ap(axi_aruser_ap),
        .axi_awvalid(axi_awvalid), .axi_arvalid(axi_arvalid),
        .axi_awuser_id(axi_awuser_id), .axi_aruser_id(axi_aruser_id),
        .axi_awlen(axi_awlen), .axi_arlen(axi_arlen),
        .axi_awready(axi_awready), .axi_arready(axi_arready),
        .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last),
        .axi_wusero_id(axi_wusero_id), .axi_rid(axi_rid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
        .axi_rdata(axi_rdata), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .uart_txd(uart_txd),
        .gpio_out(gpio_out)
    );
    // HS is reserved for the board video frontend; capture currently uses VS/DE.
    wire unused_hs = hs_in;
endmodule
