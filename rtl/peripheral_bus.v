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

    output wire [7:0] rk_tx_data,
    output wire rk_tx_valid,
    input wire rk_tx_ready,
    input wire [31:0] rk_param_data,
    input wire rk_param_update,
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

    // Same-clock CPU queue; full writes are rejected and flagged.
    localparam [31:0] RK_TX=32'h00030200, RK_STATUS=32'h00030204,
        RK_PARAM=32'h00030208, RK_SEQ=32'h0003020c,
        RK_ACK=32'h00030210, RK_CLEAR=32'h00030214;
    reg [7:0] tx_fifo [0:63];
    reg [5:0] tx_wr_ptr, tx_rd_ptr;
    reg [6:0] tx_count;
    reg tx_overflow, param_pending, param_overrun;
    reg [31:0] param_value, param_seq;
    wire tx_write = dev_we && word_access && dev_addr_wr == RK_TX;
    wire tx_push = tx_write && tx_count < 64;
    wire tx_pop = rk_tx_valid && rk_tx_ready;
    assign rk_tx_valid = rst_n && tx_count != 0;
    assign rk_tx_data = tx_fifo[tx_rd_ptr];
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_wr_ptr<=0; tx_rd_ptr<=0; tx_count<=0; tx_overflow<=0;
            param_value<=0; param_seq<=0; param_pending<=0; param_overrun<=0;
        end else begin
            if (dev_we && word_access && dev_addr_wr == RK_CLEAR) begin
                if (dev_wdata[1]) tx_overflow<=0;
                if (dev_wdata[3]) param_overrun<=0;
            end
            if (tx_push) begin
                tx_fifo[tx_wr_ptr]<=dev_wdata[7:0]; tx_wr_ptr<=tx_wr_ptr+1'b1;
            end
            if (tx_write && !tx_push) tx_overflow<=1;
            if (tx_pop) tx_rd_ptr<=tx_rd_ptr+1'b1;
            case ({tx_push,tx_pop})
                2'b10: tx_count<=tx_count+1'b1;
                2'b01: tx_count<=tx_count-1'b1;
                default: begin end
            endcase
            if (dev_we && word_access && dev_addr_wr == RK_ACK && dev_wdata == param_seq)
                param_pending<=0;
            // New update wins over simultaneous acknowledgment.
            if (rk_param_update) begin
                param_value<=rk_param_data; param_seq<=param_seq+1'b1; param_pending<=1;
                if (param_pending && !(dev_we && word_access &&
                    dev_addr_wr == RK_ACK && dev_wdata == param_seq)) param_overrun<=1;
            end
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
            else if (word_access && dev_addr_rd == RK_STATUS)
                dev_rdata <= {16'b0,1'b0,tx_count,4'b0,param_overrun,param_pending,tx_overflow,(tx_count<64)};
            else if (word_access && dev_addr_rd == RK_PARAM) dev_rdata <= param_value;
            else if (word_access && dev_addr_rd == RK_SEQ) dev_rdata <= param_seq;
            else
                // 未实现地址、不支持的访问宽度、只写寄存器读回均返回 0。
                dev_rdata <= 32'b0;
        end
    end

endmodule
