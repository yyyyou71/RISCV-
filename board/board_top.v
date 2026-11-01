module board_top #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer RESET_HOLD_CYCLES = 250000,
    parameter integer ENABLE_DUAL = 0,
    parameter integer ENABLE_FSPI = 0,
    parameter integer ENABLE_DDR = 0,ENABLE_AI = 0,ENABLE_FRAME_CONTROL = 0,
    parameter integer ENABLE_PREPROCESS = 0,
    parameter [31:0] DDR_LIMIT_BYTES = 32'h20000000
) (
    output wire tensor_we,
    output wire [8:0] tensor_addr_wr,tensor_addr_rd,
    output wire [31:0] tensor_wdata,
    input wire [31:0] tensor_rdata,
    input wire sys_clk,
    input wire spi_clk, spi_cs,
    inout wire [3:0] spi_data,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1,
    input wire core_clk,ddr_init_done,
    input wire [4:0] frame_available,
    input wire [159:0] frame_ids,
    input wire [2:0] frame_wr_slot,
    input wire frame_wr_active,shared_ddr_fault,
    input wire [31:0] video_shape,video_period,
    output wire [4:0] frame_hold_mask,
    output wire [27:0] axi_awaddr,axi_araddr,
    output wire axi_awvalid,axi_arvalid,axi_awuser_ap,axi_aruser_ap,
    output wire [3:0] axi_awlen,axi_arlen,axi_awuser_id,axi_aruser_id,
    input wire axi_awready,axi_arready,axi_wready,axi_wusero_last,axi_rvalid,axi_rlast,
    input wire [3:0] axi_wusero_id,axi_rid,
    output wire [127:0] axi_wdata,
    output wire [15:0] axi_wstrb,
    input wire [127:0] axi_rdata
);
    wire rst_n;
    wire bus_err;
    wire [1:0] gpio_out;
    reg bus_error_seen;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk),
        .key0_n(key0_n),
        .rst_n(rst_n)
    );

    soc #(.CLK_FREQ(CLOCK_HZ), .BAUD_RATE(BAUD_RATE), .ENABLE_DUAL(ENABLE_DUAL), .ENABLE_FSPI(ENABLE_FSPI),
        .ENABLE_DDR(ENABLE_DDR),.ENABLE_AI(ENABLE_AI),.ENABLE_FRAME_CONTROL(ENABLE_FRAME_CONTROL),
        .ENABLE_PREPROCESS(ENABLE_PREPROCESS),
        .DDR_LIMIT_BYTES(DDR_LIMIT_BYTES)) u_soc (
        .clk(sys_clk),
        .tensor_we(tensor_we),.tensor_addr_wr(tensor_addr_wr),.tensor_addr_rd(tensor_addr_rd),
        .tensor_wdata(tensor_wdata),.tensor_rdata(tensor_rdata),
        .rst_n(rst_n),
        .timer_irq(1'b0),
        .spi_clk(spi_clk), .spi_cs(spi_cs), .spi_data(spi_data),
        // Optional engines and external preprocessing MMIO follow board parameters.
        .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .frame_available(frame_available),.frame_ids(frame_ids),.frame_wr_slot(frame_wr_slot),
        .frame_wr_active(frame_wr_active),.shared_ddr_fault(shared_ddr_fault),
        .video_shape(video_shape),.video_period(video_period),.frame_hold_mask(frame_hold_mask),
        .pixclk_in(1'b0), .vs_in(1'b0), .hs_in(1'b0), .de_in(1'b0),
        .r_in(8'd0), .g_in(8'd0), .b_in(8'd0),
        .axi_awaddr(axi_awaddr), .axi_araddr(axi_araddr), .axi_awuser_ap(axi_awuser_ap), .axi_aruser_ap(axi_aruser_ap),
        .axi_awvalid(axi_awvalid), .axi_arvalid(axi_arvalid), .axi_awuser_id(axi_awuser_id), .axi_aruser_id(axi_aruser_id),
        .axi_awlen(axi_awlen), .axi_arlen(axi_arlen), .axi_awready(axi_awready), .axi_arready(axi_arready),
        .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last), .axi_wusero_id(axi_wusero_id),
        .axi_rid(axi_rid), .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_rdata(axi_rdata),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .uart_txd(uart_tx),
        .bus_err(bus_err),
        .gpio_out(gpio_out)
    );

    always @(posedge sys_clk) begin
        if (!rst_n)
            bus_error_seen <= 1'b0;
        else if (bus_err)
            bus_error_seen <= 1'b1;
    end

    assign led0 = rst_n && gpio_out[0];
    assign led1 = rst_n && (gpio_out[1] || bus_error_seen);
endmodule
