// CPU 外设接口适配：地址译码、UART 写请求和同步读数据返回。
module peripheral_bus #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer BAUD_RATE = 115200
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
    output reg [1:0]   gpio_out
);

    localparam [31:0] UART_TXDATA = 32'h0003_0100;
    localparam [31:0] UART_STATUS = 32'h0003_0104;
    localparam [31:0] GPIO_DATA = 32'h0003_0108;
    localparam [31:0] CYCLE_COUNT = 32'h0003_000c;

    reg [31:0] cycle_count;
    wire word_access;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 32'b0;
            gpio_out <= 2'b0;
        end
        else begin
            cycle_count <= cycle_count + 32'd1;
            if (dev_we && word_access && dev_addr_wr == GPIO_DATA)
                gpio_out <= dev_wdata[1:0];
        end
    end

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
            else if (word_access && (dev_addr_rd == CYCLE_COUNT))
                dev_rdata <= cycle_count;
            else if (word_access && (dev_addr_rd == GPIO_DATA))
                dev_rdata <= {30'b0, gpio_out};
            else
                // 未实现地址、不支持的访问宽度、只写寄存器读回均返回 0。
                dev_rdata <= 32'b0;
        end
    end

endmodule
