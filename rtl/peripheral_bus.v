// CPU 外设接口适配：地址译码、UART 写请求和同步读数据返回。
module peripheral_bus #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer BAUD_RATE = 115200,
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
)(
    output wire tensor_we,
    output wire [7:0] tensor_addr_wr,tensor_addr_rd,
    output wire [31:0] tensor_wdata,
    input wire [31:0] tensor_rdata,
    input  wire        clk,
    input  wire        rst_n,

    // 连接 Acore 的 dev_* 接口。
    input  wire        dev_we,//CPU写外设
    input  wire        dev_re,
    input  wire [31:0] dev_addr_wr,
    input  wire [31:0] dev_addr_rd,
    input  wire [31:0] dev_wdata,
    input  wire [1:0]  dev_size,
    output wire [31:0] dev_rdata,

    input wire spi_clk, spi_cs,
    inout wire [3:0] spi_data,
    input wire core_clk, ddr_init_done,
    input wire [4:0] frame_available,
    input wire [159:0] frame_ids,
    input wire [2:0] frame_wr_slot,
    input wire frame_wr_active,shared_ddr_fault,
    input wire [31:0] video_shape,video_period,
    output wire [4:0] frame_hold_mask,
    input wire pixclk_in, vs_in, de_in,
    input wire [23:0] rgb_in,
    output wire [27:0] axi_awaddr, axi_araddr,
    output wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid,
    output wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen,
    input wire axi_awready, axi_arready, axi_wready, axi_wusero_last,
    input wire [3:0] axi_wusero_id, axi_rid,
    output wire [127:0] axi_wdata,
    output wire [15:0] axi_wstrb,
    input wire [127:0] axi_rdata,
    input wire axi_rlast, axi_rvalid,

    output wire [7:0] rk_tx_data,
    output wire rk_tx_valid,
    input wire rk_tx_ready,
    input wire [31:0] rk_param_data,
    input wire rk_param_update,
    output wire        uart_txd,
    output reg [1:0]   gpio_out
);

    // Preserve video firmware addresses when video and FSPI are both enabled.
    localparam [31:0] FSPI_BASE = ENABLE_VIDEO ? 32'h00030700 : 32'h00030300;
    wire fspi_wr_hit = dev_addr_wr >= FSPI_BASE && dev_addr_wr <= FSPI_BASE+12 && dev_addr_wr[1:0]==0;
    wire fspi_rd_hit = dev_addr_rd >= FSPI_BASE && dev_addr_rd <= FSPI_BASE+12 && dev_addr_rd[1:0]==0;
    wire word_access;
    assign tensor_we=ENABLE_PREPROCESS && dev_we && word_access && dev_addr_wr[31:8]==24'h000308;
    assign tensor_addr_wr=dev_addr_wr[7:0];assign tensor_addr_rd=dev_addr_rd[7:0];
    assign tensor_wdata=dev_wdata;
    reg [31:0] legacy_rdata;
    reg fspi_read_selected;
    wire [31:0] fspi_rdata;
    always @(posedge clk) begin
        if (!rst_n) fspi_read_selected <= 0;
        else if (dev_re) fspi_read_selected <= ENABLE_FSPI && word_access &&
            fspi_rd_hit;
    end
    assign dev_rdata = fspi_read_selected ? fspi_rdata : legacy_rdata;
    generate if (ENABLE_FSPI) begin: g_fspi
        rk_fspi_adapter u_fspi (
            .clk(clk), .rst_n(rst_n), .spi_clk(spi_clk), .spi_cs(spi_cs), .spi_data(spi_data),
            .cpu_we(dev_we && word_access && fspi_wr_hit), .cpu_re(dev_re && word_access && fspi_rd_hit),
            .cpu_addr((dev_we ? dev_addr_wr : dev_addr_rd) - FSPI_BASE + 32'h00030300), .cpu_wdata(dev_wdata),
            .cpu_rdata(fspi_rdata));
    end else begin: g_no_fspi
        assign spi_data=4'bzzzz;
        assign fspi_rdata=0;
    end endgenerate

    localparam [31:0] UART_TXDATA = 32'h0003_0100;
    localparam [31:0] UART_STATUS = 32'h0003_0104;
    localparam [31:0] GPIO_DATA = 32'h0003_0108;
    localparam [31:0] CYCLE_COUNT = 32'h0003_000c;

    reg [31:0] cycle_count;

    // One synchronous CPU read stage is retained for every MMIO target.
    // The window owns its CPU/DDR CDC mailbox and serializes AI/window/video jobs.
    wire [31:0] ddr_read_data;
    wire [31:0] frame_read_data;
    generate if(ENABLE_FRAME_CONTROL!=0) begin : g_frames
        frame_mailbox u_frames(.clk(clk),.core_clk(core_clk),.rst_n(rst_n),
            .dev_we(dev_we&&word_access),.dev_addr_wr(dev_addr_wr),.dev_addr_rd(dev_addr_rd),
            .dev_wdata(dev_wdata),.read_data(frame_read_data),.available(frame_available),
            .frame_ids(frame_ids),.wr_slot(frame_wr_slot),.wr_active(frame_wr_active),
            .ddr_ready(ddr_init_done),.arb_fault(shared_ddr_fault),
            .video_shape(video_shape),.video_period(video_period),.hold_mask(frame_hold_mask));
    end else begin : g_no_frames
        assign frame_read_data=0;assign frame_hold_mask=0;
    end endgenerate
    generate if (ENABLE_DDR != 0) begin : g_ddr
        ddr_cpu_window #(.ENABLE_AI(ENABLE_AI), .AI_ACT_WIDTH(AI_ACT_WIDTH),
            .DDR_LIMIT_BYTES(DDR_LIMIT_BYTES),
            .TIMEOUT_CYCLES(DDR_TIMEOUT_CYCLES), .ENABLE_VIDEO(ENABLE_VIDEO),
            .VIDEO_FIFO_ADDR_BITS(VIDEO_FIFO_ADDR_BITS)) u_window (
            .clk(clk), .rst_n(rst_n), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
            .pixclk_in(pixclk_in), .vs_in(vs_in), .de_in(de_in), .rgb_in(rgb_in),
            .dev_we(dev_we && word_access), .dev_addr_wr(dev_addr_wr),
            .dev_addr_rd(dev_addr_rd), .dev_wdata(dev_wdata), .read_data(ddr_read_data),
            .axi_awaddr(axi_awaddr), .axi_araddr(axi_araddr),
            .axi_awuser_ap(axi_awuser_ap), .axi_aruser_ap(axi_aruser_ap),
            .axi_awvalid(axi_awvalid), .axi_arvalid(axi_arvalid),
            .axi_awuser_id(axi_awuser_id), .axi_aruser_id(axi_aruser_id),
            .axi_awlen(axi_awlen), .axi_arlen(axi_arlen),
            .axi_awready(axi_awready), .axi_arready(axi_arready),
            .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last),
            .axi_wusero_id(axi_wusero_id), .axi_rid(axi_rid),
            .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
            .axi_rdata(axi_rdata), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid)
        );
    end else begin : g_no_ddr
        assign ddr_read_data=0;
        assign axi_awaddr=0; assign axi_araddr=0;
        assign axi_awuser_ap=0; assign axi_aruser_ap=0;
        assign axi_awvalid=0; assign axi_arvalid=0;
        assign axi_awuser_id=0; assign axi_aruser_id=0;
        assign axi_awlen=0; assign axi_arlen=0;
        assign axi_wdata=0; assign axi_wstrb=0;
    end endgenerate

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
    // 0x30200 is reserved for AI, 0x30300 for video capture.
    // This CPU MMIO base is independent of the I2C slave address (0x66).
    localparam [31:0] RK_TX=32'h00030400, RK_STATUS=32'h00030404,
        RK_PARAM=32'h00030408, RK_SEQ=32'h0003040c,
        RK_ACK=32'h00030410, RK_CLEAR=32'h00030414;
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
            legacy_rdata <= 32'b0;
        end
        else if (dev_re) begin
            if (word_access && (dev_addr_rd == UART_STATUS))
                legacy_rdata <= {31'b0, !uart_busy};
            else if (word_access && (dev_addr_rd == CYCLE_COUNT))
                legacy_rdata <= cycle_count;
            else if (word_access && (dev_addr_rd == GPIO_DATA))
                legacy_rdata <= {30'b0, gpio_out};
            else if (word_access && dev_addr_rd == RK_STATUS)
                legacy_rdata <= {16'b0,1'b0,tx_count,4'b0,param_overrun,param_pending,tx_overflow,(tx_count<64)};
            else if (word_access && dev_addr_rd == RK_PARAM) legacy_rdata <= param_value;
            else if (word_access && dev_addr_rd == RK_SEQ) legacy_rdata <= param_seq;
            else if(word_access && dev_addr_rd>=32'h30600 && dev_addr_rd<=32'h30620)
                legacy_rdata<=frame_read_data;
            else if(ENABLE_PREPROCESS && word_access && dev_addr_rd[31:8]==24'h000308)
                legacy_rdata<=tensor_rdata;
            else
                // DDR/AI/video read_data is combinational, so no extra read cycle.
                legacy_rdata <= word_access ? ddr_read_data : 32'b0;
        end
    end

endmodule
