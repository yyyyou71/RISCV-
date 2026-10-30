`timescale 1ns/1ps

// 紫光 x16 DDR 原生用户接口的命令式块搬运模块。
// 所有端口都属于 core_clk 时钟域；跨时钟处理由上层负责。
//
// cmd_valid && cmd_ready 时接收一条命令，同时锁存地址、长度和方向。
// 地址和长度的单位都是字节：16 字节对齐，长度为 16～256 字节。
// 写入：先通过 wr_valid/wr_ready 收齐整块数据，再发 DDR 写命令。
// 读取：先收齐 DDR 返回的整块数据，再通过 rd_valid/rd_ready 交给上层。
// done/error 保持到下一条命令被接收，或空闲时收到 clear_status。
// 协议错误或总线超时后锁定 fault；恢复前必须一起复位本模块和 DDR IP。
// 已被 DDR 接收的命令不能通过撤销本模块状态来取消。
module ddr_block_transfer #(
    parameter integer AXI_ADDR_WIDTH = 28,
    parameter integer COLUMN_WIDTH = 10,
    parameter integer TIMEOUT_CYCLES = 4096,
    parameter [3:0] AXI_ID = 4'd0,
    parameter [32:0] LIMIT_BYTES = 33'd1 << (AXI_ADDR_WIDTH+1)
)(
    input  wire                      core_clk,
    input  wire                      rst_n,
    input  wire                      ddr_init_done,

    input  wire                      cmd_valid,
    output wire                      cmd_ready,
    input  wire                      cmd_write,
    input  wire [31:0]               cmd_addr,
    input  wire [31:0]               cmd_len,
    input  wire                      clear_status,
    output wire                      busy,
    output reg                       done,
    output reg                       error,
    output reg  [3:0]                error_code,
    output wire                      fault,

    input  wire                      wr_valid,
    output wire                      wr_ready,
    input  wire [127:0]              wr_data,
    output wire                      rd_valid,
    input  wire                      rd_ready,
    output wire [127:0]              rd_data,
    output wire                      rd_last,

    output wire [AXI_ADDR_WIDTH-1:0] axi_awaddr,
    output wire                      axi_awuser_ap,
    output wire [3:0]                axi_awuser_id,
    output wire [3:0]                axi_awlen,
    output reg                       axi_awvalid,
    input  wire                      axi_awready,
    output wire [127:0]              axi_wdata,
    output wire [15:0]               axi_wstrb,
    input  wire                      axi_wready,
    input  wire [3:0]                axi_wusero_id,
    input  wire                      axi_wusero_last,

    output wire [AXI_ADDR_WIDTH-1:0] axi_araddr,
    output wire                      axi_aruser_ap,
    output wire [3:0]                axi_aruser_id,
    output wire [3:0]                axi_arlen,
    output reg                       axi_arvalid,
    input  wire                      axi_arready,
    input  wire [127:0]              axi_rdata,
    input  wire [3:0]                axi_rid,
    input  wire                      axi_rlast,
    input  wire                      axi_rvalid
);
    localparam [3:0] ERR_NONE = 0, ERR_LENGTH = 1, ERR_ALIGNMENT = 2,
                     ERR_RANGE = 3, ERR_TIMEOUT = 4, ERR_WRITE_PROTOCOL = 5,
                     ERR_READ_PROTOCOL = 6, ERR_INIT_LOST = 7;
    localparam [3:0] S_IDLE = 0, S_FILL = 1, S_AW = 2, S_WRITE = 3,
                     S_AR = 4, S_READ = 5, S_DRAIN = 6, S_FAULT = 7;
    localparam integer WAIT_WIDTH = (TIMEOUT_CYCLES > 1) ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam integer TIMEOUT_LAST = TIMEOUT_CYCLES - 1;
    localparam [WAIT_WIDTH-1:0] WAIT_LIMIT = TIMEOUT_LAST[WAIT_WIDTH-1:0];
    // 一个原生地址单位对应一个 x16 存储位置，即两个字节。
    localparam [32:0] CAPACITY_BYTES = LIMIT_BYTES;

    reg [3:0] state;
    reg [127:0] block_buf [0:15];
    reg [4:0] total_beats, remaining_beats, segment_beats;
    reg [4:0] fill_index, data_index, segment_index, drain_index;
    reg [AXI_ADDR_WIDTH-1:0] native_addr;
    reg [WAIT_WIDTH-1:0] wait_count;

    // 原生突发只在列地址内回绕，不会自动向 bank/row 进位。
    // 当前段拍数 = min(整块剩余拍数，当前列中还能容纳的拍数)。
    function [4:0] choose_segment;
        input [COLUMN_WIDTH-1:0] column;
        input [4:0] remaining;
        reg [AXI_ADDR_WIDTH:0] column_room;
        begin
            column_room = (({{AXI_ADDR_WIDTH{1'b0}}, 1'b1}) << COLUMN_WIDTH)
                          - {{(AXI_ADDR_WIDTH+1-COLUMN_WIDTH){1'b0}}, column};
            column_room = column_room >> 3;
            choose_segment = (column_room < {{(AXI_ADDR_WIDTH-4){1'b0}}, remaining})
                             ? column_room[4:0] : remaining;
        end
    endfunction

    wire [32:0] command_end = {1'b0, cmd_addr} + {1'b0, cmd_len};
    wire [AXI_ADDR_WIDTH-1:0] next_native_addr = native_addr +
                      ({{(AXI_ADDR_WIDTH-5){1'b0}}, segment_beats} << 3);
    wire [4:0] next_remaining = remaining_beats - segment_beats;
    wire aw_fire = axi_awvalid && axi_awready;
    wire ar_fire = axi_arvalid && axi_arready;
    wire w_fire = axi_wready && ((state == S_WRITE) || ((state == S_AW) && aw_fire));
    wire r_fire = axi_rvalid && ((state == S_READ) || ((state == S_AR) && ar_fire));
    wire waiting_bus = (state == S_AW) || (state == S_WRITE) ||
                       (state == S_AR) || (state == S_READ);
    wire bus_progress = aw_fire || ar_fire || w_fire || r_fire;
    wire segment_last = (segment_index == segment_beats - 5'd1);

    assign fault = (state == S_FAULT);
    assign busy = (state != S_IDLE);
    assign cmd_ready = rst_n && ddr_init_done && (state == S_IDLE);
    assign wr_ready = rst_n && ddr_init_done && (state == S_FILL);
    assign rd_valid = rst_n && (state == S_DRAIN);
    assign rd_data = block_buf[drain_index[3:0]];
    assign rd_last = rd_valid && (drain_index == total_beats - 5'd1);

    assign axi_awaddr = native_addr;
    assign axi_araddr = native_addr;
    assign axi_awlen = segment_beats[3:0] - 4'd1; // 16 拍编码为 len=15
    assign axi_arlen = segment_beats[3:0] - 4'd1;
    assign axi_awuser_ap = 1'b0;
    assign axi_aruser_ap = 1'b0;
    assign axi_awuser_id = AXI_ID;
    assign axi_aruser_id = AXI_ID;
    // 数据先于 WREADY 准备好；即使地址和首拍同时接收，也能取到正确数据。
    assign axi_wdata = block_buf[data_index[3:0]];
    // 致命错误后，DDR 仍可能排空已经接收的写命令，此时屏蔽后续写入。
    // 之前已经完成的写入无法回滚，错误恢复需要系统共同复位。
    assign axi_wstrb = ((state == S_AW) || (state == S_WRITE)) ? 16'hffff : 16'h0000;

    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 0; error <= 0; error_code <= ERR_NONE;
            axi_awvalid <= 0; axi_arvalid <= 0;
            total_beats <= 0; remaining_beats <= 0; segment_beats <= 1;
            fill_index <= 0; data_index <= 0; segment_index <= 0; drain_index <= 0;
            native_addr <= 0; wait_count <= 0;
            // 不复位整块 RAM：写前先收齐数据，读结果全部有效后才拉高 rd_valid。
        end else begin
            // 地址请求在握手前持续有效，fault 状态也不提前撤回。
            // 只有共同复位才能安全中断尚未完成的原生总线事务。
            if (aw_fire) axi_awvalid <= 0;
            if (ar_fire) axi_arvalid <= 0;

            if ((state == S_IDLE) && clear_status) begin
                done <= 0; error <= 0; error_code <= ERR_NONE;
            end
            if (!waiting_bus || bus_progress)
                wait_count <= 0;
            else if (wait_count != WAIT_LIMIT)
                wait_count <= wait_count + 1'b1;

            case (state)
                S_IDLE: if (cmd_valid && cmd_ready) begin
                    done <= 0; error <= 0; error_code <= ERR_NONE;
                    if ((cmd_len == 0) || (cmd_len > 256)) begin
                        error <= 1; error_code <= ERR_LENGTH;
                    end else if ((cmd_addr[3:0] != 0) || (cmd_len[3:0] != 0)) begin
                        error <= 1; error_code <= ERR_ALIGNMENT;
                    end else if (command_end > CAPACITY_BYTES) begin
                        error <= 1; error_code <= ERR_RANGE;
                    end else begin
                        native_addr <= cmd_addr[AXI_ADDR_WIDTH:1];
                        total_beats <= cmd_len[8:4];
                        remaining_beats <= cmd_len[8:4];
                        segment_beats <= choose_segment(cmd_addr[COLUMN_WIDTH:1], cmd_len[8:4]);
                        fill_index <= 0; data_index <= 0; segment_index <= 0; drain_index <= 0;
                        if (cmd_write) begin
                            state <= S_FILL;
                        end else begin
                            state <= S_AR;
                            axi_arvalid <= 1;
                        end
                    end
                end

                S_FILL: if (wr_valid && wr_ready) begin
                    block_buf[fill_index[3:0]] <= wr_data;
                    if (fill_index == total_beats - 5'd1) begin
                        state <= S_AW;
                        axi_awvalid <= 1;
                    end else begin
                        fill_index <= fill_index + 5'd1;
                    end
                end

                S_AW, S_WRITE: begin
                    if ((state == S_AW) && aw_fire) state <= S_WRITE;
                    if (w_fire) begin
                        if ((axi_wusero_id != AXI_ID) || (axi_wusero_last != segment_last)) begin
                            state <= S_FAULT; error <= 1; error_code <= ERR_WRITE_PROTOCOL;
                        end else begin
                            data_index <= data_index + 5'd1;
                            if (segment_last) begin
                                if (remaining_beats == segment_beats) begin
                                    state <= S_IDLE; done <= 1;
                                end else begin
                                    native_addr <= next_native_addr;
                                    remaining_beats <= next_remaining;
                                    segment_beats <= choose_segment(next_native_addr[COLUMN_WIDTH-1:0], next_remaining);
                                    segment_index <= 0;
                                    state <= S_AW; axi_awvalid <= 1;
                                end
                            end else begin
                                segment_index <= segment_index + 5'd1;
                            end
                        end
                    end
                end

                S_AR, S_READ: begin
                    if ((state == S_AR) && ar_fire) state <= S_READ;
                    if (r_fire) begin
                        if ((axi_rid != AXI_ID) || (axi_rlast != segment_last)) begin
                            state <= S_FAULT; error <= 1; error_code <= ERR_READ_PROTOCOL;
                        end else begin
                            block_buf[data_index[3:0]] <= axi_rdata;
                            data_index <= data_index + 5'd1;
                            if (segment_last) begin
                                if (remaining_beats == segment_beats) begin
                                    state <= S_DRAIN;
                                end else begin
                                    native_addr <= next_native_addr;
                                    remaining_beats <= next_remaining;
                                    segment_beats <= choose_segment(next_native_addr[COLUMN_WIDTH-1:0], next_remaining);
                                    segment_index <= 0;
                                    state <= S_AR; axi_arvalid <= 1;
                                end
                            end else begin
                                segment_index <= segment_index + 5'd1;
                            end
                        end
                    end
                end

                S_DRAIN: if (rd_valid && rd_ready) begin
                    if (rd_last) begin
                        state <= S_IDLE; done <= 1;
                    end else begin
                        drain_index <= drain_index + 5'd1;
                    end
                end

                S_FAULT: begin end // 等待系统共同复位搬运模块和 DDR 控制器。
                default: begin
                    state <= S_FAULT; error <= 1; error_code <= ERR_READ_PROTOCOL;
                end
            endcase

            // 允许上层在收集写数据、取走读结果时暂停，不按 DDR 超时处理。
            // 看门狗只检查原生总线长时间没有握手或数据返回的情况。
            if (waiting_bus && !bus_progress && (wait_count == WAIT_LIMIT)) begin
                state <= S_FAULT; done <= 0; error <= 1; error_code <= ERR_TIMEOUT;
            end
            if ((state != S_IDLE) && (state != S_FAULT) && !ddr_init_done) begin
                state <= S_FAULT; done <= 0; error <= 1; error_code <= ERR_INIT_LOST;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if ((AXI_ADDR_WIDTH < 5) || (AXI_ADDR_WIDTH < COLUMN_WIDTH) || (AXI_ADDR_WIDTH > 30) ||
            (COLUMN_WIDTH < 4) || (TIMEOUT_CYCLES < 1))
            $fatal(1, "ddr_block_transfer: invalid address geometry or watchdog");
    end
    // synthesis translate_on
endmodule
