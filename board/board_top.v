module board_top #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer RESET_HOLD_CYCLES = 250000,
    parameter integer IIC_BOOT_TEST = 0,
    parameter integer ENABLE_DUAL = 0
) (
    input wire sys_clk,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1,
    input wire iic_scl,
    inout wire iic_sda
);
    wire rst_n;
    wire bus_err;
    wire [1:0] gpio_out;
    reg bus_error_seen;
    wire [31:0] rk_param_data;
    wire rk_param_update;
    wire rk_uplink_ready;
    reg rk_test_byte_sent;
    wire [7:0] cpu_rk_tx_data;
    wire cpu_rk_tx_valid;
    wire boot_pending = IIC_BOOT_TEST && !rk_test_byte_sent;

    // Bring-up only: enqueue 0xA5 once after each board reset.
    // Disable IIC_BOOT_TEST when replacing this source with a real FIFO.
    always @(posedge sys_clk) begin
        if (!rst_n)
            rk_test_byte_sent <= 1'b0;
        else if (IIC_BOOT_TEST && !rk_test_byte_sent && rk_uplink_ready)
            rk_test_byte_sent <= 1'b1;
    end

    rk_iic_adapter #(
        .CLK_FREQ_MHZ(CLOCK_HZ / 1000000),
        .I2C_ADDRESS(7'h66)
    ) u_rk_iic (
        .clk(sys_clk), .rst_n(rst_n),
        .iic_scl(iic_scl), .iic_sda(iic_sda),
        .param_data(rk_param_data), .param_update(rk_param_update),
        .uplink_data(boot_pending ? 8'hA5 : cpu_rk_tx_data),
        .uplink_valid(rst_n && (boot_pending || cpu_rk_tx_valid)),
        .uplink_ready(rk_uplink_ready)
    );
    // CPU and IIC application interfaces share sys_clk.

    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk),
        .key0_n(key0_n),
        .rst_n(rst_n)
    );

    soc #(.CLK_FREQ(CLOCK_HZ), .BAUD_RATE(BAUD_RATE), .ENABLE_DUAL(ENABLE_DUAL)) u_soc (
        .clk(sys_clk),
        .rst_n(rst_n),
        .timer_irq(1'b0),
        // DDR/AI remain disabled in the existing board image until M2 wiring.
        .core_clk(sys_clk), .ddr_init_done(1'b0),
        .pixclk_in(1'b0), .vs_in(1'b0), .hs_in(1'b0), .de_in(1'b0),
        .r_in(8'd0), .g_in(8'd0), .b_in(8'd0),
        .axi_awaddr(), .axi_araddr(), .axi_awuser_ap(), .axi_aruser_ap(),
        .axi_awvalid(), .axi_arvalid(), .axi_awuser_id(), .axi_aruser_id(),
        .axi_awlen(), .axi_arlen(), .axi_awready(1'b0), .axi_arready(1'b0),
        .axi_wready(1'b0), .axi_wusero_last(1'b0), .axi_wusero_id(4'd0),
        .axi_rid(4'd0), .axi_wdata(), .axi_wstrb(), .axi_rdata(128'd0),
        .axi_rlast(1'b0), .axi_rvalid(1'b0),
        .rk_tx_data(cpu_rk_tx_data), .rk_tx_valid(cpu_rk_tx_valid),
        .rk_tx_ready(rk_uplink_ready && !boot_pending),
        .rk_param_data(rk_param_data), .rk_param_update(rk_param_update),
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
