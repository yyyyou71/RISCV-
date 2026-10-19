// SoC top level: CPU (including ROM/RAM) plus memory-mapped peripherals.
module soc #(
//串口参数为115200 参考时钟频率25Mhz 参数配置在外设总线文件中
)(
    input  wire clk,
    input  wire rst_n,
    output wire uart_txd,
    output wire bus_err
);
    wire        dev_we;
    wire        dev_re;
    wire [31:0] dev_addr_wr;
    wire [31:0] dev_addr_rd;
    wire [31:0] dev_wdata;
    wire [31:0] dev_rdata;
    wire [1:0]  dev_size;

    Acore u_core (
        .clk(clk),
        .rst_n(rst_n),
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
//串口参数为115200 参考时钟频率25Mhz 参数配置在外设总线文件中
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
        .uart_txd(uart_txd)
    );
endmodule
