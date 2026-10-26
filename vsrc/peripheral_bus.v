`default_nettype none
// CPU 外设接口适配：UART、可选 DDR 块窗口及同步读数据返回。
module peripheral_bus #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer BAUD_RATE = 115200,
    parameter integer ENABLE_DDR = 0,
    parameter integer ENABLE_AI = 0,
    parameter integer DDR_TIMEOUT_CYCLES = 4096,
    parameter integer AI_ACT_WIDTH = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // 连接 Acore 的 dev_* 接口。
    input  wire        dev_we,//CPU写外设
    input  wire        dev_re,
    input  wire [31:0] dev_addr_wr,
    input  wire [31:0] dev_addr_rd,
    input  wire [31:0] dev_wdata,
    input  wire [1:0]  dev_size,
    output reg  [31:0] dev_rdata,

    output wire        uart_txd,

    // ENABLE_DDR=1 时接紫光 DDR IP 用户接口；CPU/DDR 时钟无需同源。
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

    localparam [31:0] UART_TXDATA = 32'h0003_0100;
    localparam [31:0] UART_STATUS = 32'h0003_0104;

    wire word_access;
    wire [31:0] ddr_read_data;
    generate if (ENABLE_DDR != 0) begin : g_ddr
        ddr_cpu_window #(.TIMEOUT_CYCLES(DDR_TIMEOUT_CYCLES),.ENABLE_AI(ENABLE_AI),.AI_ACT_WIDTH(AI_ACT_WIDTH)) u_window (
            .clk(clk), .core_clk(core_clk), .rst_n(rst_n), .ddr_init_done(ddr_init_done),
            .dev_we(dev_we && word_access), .dev_addr_wr(dev_addr_wr),
            .dev_addr_rd(dev_addr_rd), .dev_wdata(dev_wdata), .read_data(ddr_read_data),
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
    end else begin : g_no_ddr
        assign ddr_read_data = 0;
        assign axi_awaddr = '0;
        assign axi_awuser_ap = '0;
        assign axi_awuser_id = '0;
        assign axi_awlen = '0;
        assign axi_awvalid = '0;
        assign axi_wdata = '0;
        assign axi_wstrb = '0;
        assign axi_araddr = '0;
        assign axi_aruser_ap = '0;
        assign axi_aruser_id = '0;
        assign axi_arlen = '0;
        assign axi_arvalid = '0;
    end endgenerate

    wire uart_busy;
    wire uart_tx_start;

    // 第一版只接受对齐的 32 位访问，地址匹配同时保证了对齐。
    assign word_access = (dev_size == 2'b10);

    // 只有命中 TXDATA 的有效写操作才能启动 UART。
    // 忙时忽略写入；软件应先轮询 STATUS[0]，等它为 1 再写。
    assign uart_tx_start = rst_n && dev_we && word_access &&
                           (dev_addr_wr == UART_TXDATA) && !uart_busy;

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (uart_tx_start),
        .tx_data  (dev_wdata[7:0]),
        .tx       (uart_txd),
        .busy     (uart_busy)
    );

    // 与 Acore 的访存/写回时序匹配：在采样读请求的上升沿
    // 更新读数据寄存器。无读请求时保持上次结果。
    always @(posedge clk) begin
        if (!rst_n) begin
            dev_rdata <= 32'b0;
        end
        else if (dev_re) begin
            if (word_access && (dev_addr_rd == UART_STATUS))
                dev_rdata <= {31'b0, !uart_busy};
            else if (word_access)
                dev_rdata <= ddr_read_data;
            else
                // 未实现地址、不支持的访问宽度、只写寄存器读回均返回 0。
                dev_rdata <= 32'b0;
        end
    end

endmodule

`default_nettype wire
