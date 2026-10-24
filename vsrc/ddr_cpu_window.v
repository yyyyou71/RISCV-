`default_nettype none
`timescale 1ns/1ps

// CPU 的 DDR 块窗口：32 位 MMIO，256 字节缓冲，独立 CPU/DDR 时钟。
// 跨域采用稳定邮箱 + 双级同步的请求/应答翻转位。请求未应答前，
// CPU 不得改写配置和窗口；DDR 应答后也保持结果，直到下一条请求到达。
// 多位邮箱不能逐位同步。上板需对邮箱总线添加跨域最大延迟约束，见文档。
// rst_n 必须同时复位 DDR IP；禁止仅复位本模块来取消原生事务。
module ddr_cpu_window #(
    parameter integer AXI_ADDR_WIDTH = 28,
    parameter integer COLUMN_WIDTH = 10,
    parameter integer TIMEOUT_CYCLES = 4096
)(
    input wire clk,
    input wire core_clk,
    input wire rst_n,
    input wire ddr_init_done,
    input wire dev_we, // 已由外设总线过滤为对齐的 32 位写
    input wire [31:0] dev_addr_wr,
    input wire [31:0] dev_addr_rd,
    input wire [31:0] dev_wdata,
    output reg [31:0] read_data, // 组合输出，由外设总线在 CPU 时钟沿寄存
    output wire [AXI_ADDR_WIDTH-1:0]    axi_awaddr,
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

    output wire [AXI_ADDR_WIDTH-1:0]    axi_araddr,
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
    localparam [31:0] CTRL = 32'h0003_1000, STATUS = 32'h0003_1004,
                     ADDRESS = 32'h0003_1008, LENGTH = 32'h0003_100c,
                     ERROR_CODE = 32'h0003_1010;
    // 四条 32 位通道组成一个 128 位拍。邮箱用寄存器实现，不依赖双时钟 RAM IP。
    reg [31:0] cpu_buf [0:63];
    reg [63:0] valid_words;
    reg [127:0] core_buf [0:15];
    reg [31:0] address_reg, length_reg;
    reg direction_reg, request_toggle;
    reg cpu_busy, cpu_done, cpu_error, cpu_fault;
    reg [3:0] cpu_code;
    reg ack_toggle;
    reg response_error, response_fault;
    reg [3:0] response_code;

    // 复位异步拉低、各域同步释放；CPU 和 DDR 的频率及相位均可独立改变。
    // 复位链的末级只用于异步复位，首级仅在本时钟域移位。
    /* verilator lint_off SYNCASYNCNET */
    (* ASYNC_REG = "TRUE" *) reg [1:0] cpu_reset_sync, core_reset_sync;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cpu_reset_sync <= 0;
        else cpu_reset_sync <= {cpu_reset_sync[0], 1'b1};
    always @(posedge core_clk or negedge rst_n)
        if (!rst_n) core_reset_sync <= 0;
        else core_reset_sync <= {core_reset_sync[0], 1'b1};
    wire cpu_reset_n = cpu_reset_sync[1];
    wire core_reset_n = core_reset_sync[1];

    (* ASYNC_REG = "TRUE" *) reg req_meta, req_sync, ack_meta, ack_sync;
    (* ASYNC_REG = "TRUE" *) reg init_meta, init_sync;
    always @(posedge clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            ack_meta <= 0; ack_sync <= 0; init_meta <= 0; init_sync <= 0;
        end else begin
            ack_meta <= ack_toggle; ack_sync <= ack_meta;
            init_meta <= ddr_init_done; init_sync <= init_meta;
        end
    end
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin req_meta <= 0; req_sync <= 0; end
        else begin req_meta <= request_toggle; req_sync <= req_meta; end
    end

    wire ready = cpu_reset_n && init_sync && !cpu_busy && !cpu_fault;
    wire window_wr = dev_addr_wr[31:8] == 24'h000311 && dev_addr_wr[1:0] == 0;
    wire window_rd = dev_addr_rd[31:8] == 24'h000311 && dev_addr_rd[1:0] == 0;
    integer cpu_i;
    always @(posedge clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            address_reg <= 0; length_reg <= 0; direction_reg <= 0; request_toggle <= 0;
            cpu_busy <= 0; cpu_done <= 0; cpu_error <= 0; cpu_fault <= 0; cpu_code <= 0;
            valid_words <= 0;
        end else begin
            // 完成位跨域稳定后，结果邮箱也已稳定至少两个 CPU 周期。
            if (cpu_busy && ack_sync == request_toggle) begin
                cpu_busy <= 0; cpu_done <= !response_error;
                cpu_error <= response_error; cpu_fault <= response_fault;
                cpu_code <= response_code;
                if (!direction_reg && !response_error) begin
                    for (cpu_i = 0; cpu_i < 64; cpu_i = cpu_i + 1)
                        if (cpu_i < (length_reg >> 2)) begin
                            cpu_buf[cpu_i] <= core_buf[cpu_i / 4][(cpu_i % 4)*32 +: 32];
                            valid_words[cpu_i] <= 1;
                        end
                end
            end
            // 忙时所有配置、窗口写和再次启动均忽略，保护正在传递的邮箱。
            if (dev_we && !cpu_busy && !cpu_fault) begin
                if (window_wr) begin
                    cpu_buf[dev_addr_wr[7:2]] <= dev_wdata;
                    valid_words[dev_addr_wr[7:2]] <= 1;
                end
                case (dev_addr_wr)
                    ADDRESS: address_reg <= dev_wdata;
                    LENGTH: length_reg <= dev_wdata;
                    CTRL: begin
                        if (dev_wdata[2]) begin
                            cpu_done <= 0; cpu_error <= 0; cpu_code <= 0;
                        end
                        if (dev_wdata[0]) begin
                            cpu_done <= 0;
                            if (ready) begin
                                direction_reg <= dev_wdata[1];
                                request_toggle <= !request_toggle;
                                cpu_busy <= 1; cpu_error <= 0; cpu_code <= 0;
                            end else begin cpu_error <= 1; cpu_code <= 8; end
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end

    always @* begin
        read_data = 0;
        case (dev_addr_rd)
            STATUS: read_data = {26'd0, init_sync, ready, cpu_fault, cpu_error, cpu_done, cpu_busy};
            ADDRESS: read_data = address_reg;
            LENGTH: read_data = length_reg;
            ERROR_CODE: read_data = {28'd0, cpu_code};
            default: if (window_rd && !cpu_busy && valid_words[dev_addr_rd[7:2]])
                read_data = cpu_buf[dev_addr_rd[7:2]];
        endcase
    end

    localparam [1:0] C_IDLE = 0, C_COMMAND = 1, C_ACTIVE = 2;
    reg [1:0] core_state;
    reg core_direction;
    reg [31:0] core_address, core_length;
    reg [4:0] stream_index;
    wire cmd_ready, transfer_done, transfer_error, transfer_fault;
    wire unused_transfer_busy, unused_rd_last;
    wire [3:0] transfer_code;
    wire wr_ready, rd_valid;
    wire [127:0] rd_data;
    wire wr_valid = core_state == C_ACTIVE && core_direction && stream_index < core_length[8:4];
    wire rd_ready = core_state == C_ACTIVE && !core_direction;
    integer core_i, lane;
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            core_state <= C_IDLE; core_direction <= 0; core_address <= 0; core_length <= 0;
            stream_index <= 0; ack_toggle <= 0;
            response_error <= 0; response_fault <= 0; response_code <= 0;
        end else begin
            case (core_state)
                C_IDLE: if (req_sync != ack_toggle) begin
                    // 请求翻转已通过两级同步，此时 CPU 邮箱保持不动。
                    core_address <= address_reg; core_length <= length_reg;
                    core_direction <= direction_reg; stream_index <= 0;
                    for (core_i = 0; core_i < 16; core_i = core_i + 1)
                        for (lane = 0; lane < 4; lane = lane + 1)
                            core_buf[core_i][lane*32 +: 32] <= valid_words[core_i*4+lane]
                                ? cpu_buf[core_i*4+lane] : 32'd0;
                    core_state <= C_COMMAND;
                end
                C_COMMAND: begin
                    if (!ddr_init_done) begin
                        // 初始化在 CPU 提交后撤销，且尚未发出 DDR 请求：可重试。
                        response_error <= 1; response_fault <= 0; response_code <= 8;
                        ack_toggle <= req_sync; core_state <= C_IDLE;
                    end else if (cmd_ready) core_state <= C_ACTIVE;
                end
                C_ACTIVE: begin
                    if (wr_valid && wr_ready) stream_index <= stream_index + 1'b1;
                    if (rd_valid && rd_ready) begin
                        core_buf[stream_index[3:0]] <= rd_data;
                        stream_index <= stream_index + 1'b1;
                    end
                    if (transfer_done || transfer_error) begin
                        response_error <= transfer_error; response_fault <= transfer_fault;
                        response_code <= transfer_code;
                        ack_toggle <= req_sync; core_state <= C_IDLE;
                    end
                end
                default: core_state <= C_IDLE;
            endcase
        end
    end

    ddr_block_transfer #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .COLUMN_WIDTH(COLUMN_WIDTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_transfer (
        .core_clk(core_clk), .rst_n(core_reset_n), .ddr_init_done(ddr_init_done),
        .cmd_valid(core_state == C_COMMAND && ddr_init_done), .cmd_ready(cmd_ready),
        .cmd_write(core_direction), .cmd_addr(core_address), .cmd_len(core_length),
        .clear_status(1'b0), .busy(unused_transfer_busy), .done(transfer_done), .error(transfer_error),
        .error_code(transfer_code), .fault(transfer_fault),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_data(core_buf[stream_index[3:0]]),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_data(rd_data), .rd_last(unused_rd_last),
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
