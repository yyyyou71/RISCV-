module soc #(
    parameter integer CLK_FREQ = 25000000,
    parameter integer BAUD_RATE = 115200
) (
    input wire clk,
    input wire rst_n,
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

    Acore u_core (
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
        .uart_txd(uart_txd),
        .gpio_out(gpio_out)
    );
endmodule
