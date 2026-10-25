`default_nettype none
// SoC：CPU 自带 ROM/RAM，外设总线支持 UART 和可选的 DDR 块窗口。
module soc #(
    parameter integer CLK_FREQ = 25_000_000,
    parameter integer BAUD_RATE = 115200,
    parameter integer ENABLE_DDR = 0,
    parameter integer ENABLE_AI = 0,
    parameter integer DDR_TIMEOUT_CYCLES = 4096
)(
    input  wire clk,
    input  wire rst_n,
    output wire uart_txd,
    output wire bus_err,
    input wire core_clk,
    input wire ddr_init_done,
    output wire [27:0]                  axi_awaddr,
    output wire                         axi_awuser_ap,
    output wire [3:0]                   axi_awuser_id,
    output wire [3:0]                   axi_awlen,
    output wire                         axi_awvalid,
    input  wire                         axi_awready,
    output wire [127:0]                 axi_wdata,
    output wire [15:0]                  axi_wstrb,
    input  wire                         axi_wready,
    input  wire [3:0]                   axi_wusero_id,
    input  wire                         axi_wusero_last,

    output wire [27:0]                  axi_araddr,
    output wire                         axi_aruser_ap,
    output wire [3:0]                   axi_aruser_id,
    output wire [3:0]                   axi_arlen,
    output wire                         axi_arvalid,
    input  wire                         axi_arready,
    input  wire [127:0]                 axi_rdata,
    input  wire [3:0]                   axi_rid,
    input  wire                         axi_rlast,
    input  wire                         axi_rvalid
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
        .CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE),
        .ENABLE_DDR(ENABLE_DDR), .ENABLE_AI(ENABLE_AI), .DDR_TIMEOUT_CYCLES(DDR_TIMEOUT_CYCLES)
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
        .uart_txd(uart_txd), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr),
        .axi_awuser_ap(axi_awuser_ap),
        .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr),
        .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_rdata(axi_rdata),
        .axi_rid(axi_rid),
        .axi_rlast(axi_rlast),
        .axi_rvalid(axi_rvalid)
    );
endmodule

`default_nettype wire
