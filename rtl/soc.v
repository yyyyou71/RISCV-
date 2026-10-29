module soc #(
    parameter integer CLK_FREQ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer ENABLE_DUAL = 0
) (
    input wire clk,
    input wire rst_n,
    output wire [7:0] rk_tx_data,
    output wire rk_tx_valid,
    input wire rk_tx_ready,
    input wire [31:0] rk_param_data,
    input wire rk_param_update,
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
        .timer_irq(1'b0),
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
        .BAUD_RATE(BAUD_RATE)
    ) u_peripheral_bus (
        .clk(clk),
        .rst_n(rst_n),
        .dev_we(dev_we),
        .dev_re(dev_re),
        .dev_addr_wr(dev_addr_wr),
        .dev_addr_rd(dev_addr_rd),
        .dev_wdata(dev_wdata),
        .dev_size(dev_size),
        .dev_rdata(dev_rdata),
        .rk_tx_data(rk_tx_data), .rk_tx_valid(rk_tx_valid), .rk_tx_ready(rk_tx_ready),
        .rk_param_data(rk_param_data), .rk_param_update(rk_param_update),
        .uart_txd(uart_txd),
        .gpio_out(gpio_out)
    );
endmodule
