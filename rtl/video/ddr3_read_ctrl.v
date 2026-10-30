// =============================================================================
// ddr3_read_ctrl — 精简读控制器 (Phase 3)
// -----------------------------------------------------------------------------
// AXI4 128bit 突发读 DDR3 → 异步 FIFO(128→128, core_clk→pclk_div2) → 128bit 用户读
//
// 改造点（相对原 ddr_2_fifo_controller）：
//   1. 删 clr/clr_valid — clr 被接死为 1'b0
//   2. 删 SOF_MAGIC 搜索/验证 — 验证移到写侧, 读侧不扫描
//   3. 删 first_word 武装/清除 — 不再需要
//   4. 删 axi_rready — IP 无此端口, R 为 push 型
//   5. 删 dbg_* 粘滞寄存器 — 调试完成
//   6. FSM: S_IDLE→S_WAIT_ROOM→S_AR→S_R, 反压移到 AR 侧
//   7. frame_done 查询替代方案甲 target_slot 计算
//   8. 统一线性地址公式: (rd_frame_id<<22) + 逐突发递增
//   9. 回退重读: 帧槽绝对地址可随机寻址
//
// 关键约束（来自 DDR3 IP 实测，详见改造计划 §0）：
//   C3: R 无 rready — IP push 型, 反压前移到 AR 侧 (S_WAIT_ROOM)
// =============================================================================
module ddr3_read_ctrl #(
    parameter AXI_DATA_WIDTH     = 128,
    parameter AXI_ADDR_WIDTH     = 28,
    parameter BURST_BEAT_CNT     = 16,
    parameter AXI_ARLEN          = BURST_BEAT_CNT - 1,       // 15

    parameter PIXEL_WIDTH        = 16,
    parameter AXI_BYTE_WIDTH     = AXI_DATA_WIDTH / 8,       // 16
    parameter H_ACTIVE           = 1920,
    parameter V_ACTIVE           = 1080,
    parameter FRAME_BYTE_CNT     = H_ACTIVE * V_ACTIVE * PIXEL_WIDTH / 8,   // 4147200
    parameter FRAME_BURST_CNT    = FRAME_BYTE_CNT / (AXI_BYTE_WIDTH * BURST_BEAT_CNT), // 16200
    parameter FRAME_SHIFT        = 22,                       // 原生地址槽步长 2^22

    parameter FIFO_WR_WIDTH      = 128,
    parameter FIFO_RD_WIDTH      = 128,
    parameter FIFO_WR_ADDR_WIDTH = 6,                        // 深度 64
    parameter FIFO_RD_ADDR_WIDTH = 6
) (
    output wire [4:0] protect_mask,
    input                          rst_n,
    input                          clk_w,                    // 用户读时钟 (pclk_div2)
    input                          clk_r,                    // AXI/核心时钟 (core_clk)

    // 帧槽状态 (从写控制器来)
    input      [4:0]               frame_done,               // bit[i]=1 表示槽 i 已完成写
    output reg                     frame_consumed,           // 单拍脉冲, 通知写侧清除 frame_done
    output reg [2:0]               consumed_frame_id,

    input                          ddr_init_done,
    output                         read_busy,
    output reg                     read_done,                // 整帧读完成(1拍脉冲)

    // 用户读 FIFO
    output [FIFO_RD_WIDTH-1:0]     data_out,
    input                          rd_en,
    output                         rd_empty,
    output                         almost_empty,

    // AXI4 读地址通道 (IP 无 arsize/arburst/arid 端口, 见 §0)
    output reg [AXI_ADDR_WIDTH-1:0] axi_araddr,
    output                          axi_aruser_ap,
    output     [3:0]                axi_aruser_id,
    output     [3:0]                axi_arlen,
    output reg                      axi_arvalid,
    input                           axi_arready,

    // AXI4 读数据通道 (push 型, 无 rready — IP 一旦接受 AR 即推数据, 不可反压)
    input  [AXI_DATA_WIDTH-1:0]    axi_rdata,
    input                           axi_rlast,
    input                           axi_rvalid
);

    // ====================== 派生常量 ======================
    localparam BURST_PER_LINE = (H_ACTIVE * PIXEL_WIDTH / 8) / (AXI_BYTE_WIDTH * BURST_BEAT_CNT); // 15
    localparam [FIFO_WR_ADDR_WIDTH:0] FIFO_WR_DEPTH = (1 << FIFO_WR_ADDR_WIDTH);                   // 64

    // ====================== 状态机 ==========================
    localparam S_IDLE       = 4'b0001;
    localparam S_WAIT_ROOM  = 4'b0010;
    localparam S_AR         = 4'b0100;
    localparam S_R          = 4'b1000;

    reg [3:0] state, next_state;

    // ====================== 内部信号 ======================
    wire wr_rst = !rst_n;
    wire [FIFO_WR_WIDTH-1:0] fifo_wr_data;
    wire                     fifo_wr_en;
    wire                     fifo_wr_full;
    wire [FIFO_WR_ADDR_WIDTH:0] fifo_wr_water_level;

    reg [15:0] burst_cnt;           // 已完成突发数 0..16200
    reg [3:0]  burst_in_line;       // 行内突发序号 0..14 (用于 aruser_ap)
    reg        ar_done;             // E8: AR 单次握手锁存
    reg [2:0]  rd_frame_id_latched; // 本次读的目标帧槽 (S_IDLE 时锁存)

    wire frame_done_any = |frame_done;
    assign protect_mask=(state!=S_IDLE) ? (5'b1<<rd_frame_id_latched):
        ((ddr_init_done && frame_done_any) ? (5'b1<<rd_frame_id_comb):5'b0);
    assign read_busy = (state != S_IDLE);

    // ====================== frame_done 优先编码器 (组合逻辑) ======================
    wire [2:0] rd_frame_id_comb;
    assign rd_frame_id_comb = frame_done[4] ? 3'd4 :
                              frame_done[3] ? 3'd3 :
                              frame_done[2] ? 3'd2 :
                              frame_done[1] ? 3'd1 :
                              frame_done[0] ? 3'd0 : 3'd0;

    // ====================== 锁存目标帧槽 ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            rd_frame_id_latched <= 3'd0;
        else if (state == S_IDLE && ddr_init_done && frame_done_any)
            rd_frame_id_latched <= rd_frame_id_comb;
    end

    // ====================== FIFO 空间检查 (AR 侧反压) ======================
    reg ddr_rd_rq;
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            ddr_rd_rq <= 1'b0;
        else if (fifo_wr_water_level <= (FIFO_WR_DEPTH - BURST_BEAT_CNT))
            ddr_rd_rq <= 1'b1;
        else
            ddr_rd_rq <= 1'b0;
    end

    // ====================== FSM 时序 ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (ddr_init_done && frame_done_any)
                    next_state = S_WAIT_ROOM;
            end
            S_WAIT_ROOM: begin
                if (burst_cnt >= FRAME_BURST_CNT)
                    next_state = S_IDLE;
                else if (ddr_rd_rq && !fifo_wr_full)
                    next_state = S_AR;
            end
            S_AR: begin
                if (axi_arvalid && axi_arready)
                    next_state = S_R;
            end
            S_R: begin
                if (axi_rvalid && axi_rlast)
                    next_state = S_WAIT_ROOM;
            end
            default: next_state = S_IDLE;
        endcase
    end

    // ====================== AXI 读地址 (统一线性公式) ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            axi_araddr <= {AXI_ADDR_WIDTH{1'b0}};
        else if (state == S_IDLE && ddr_init_done && frame_done_any)
            axi_araddr <= {rd_frame_id_comb, {FRAME_SHIFT{1'b0}}};   // slot << 22
        else if (state == S_R && axi_rvalid && axi_rlast)
            axi_araddr <= axi_araddr + (AXI_BYTE_WIDTH * BURST_BEAT_CNT); // +256B
    end

    // ====================== 突发计数 ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            burst_cnt <= 16'd0;
        else if (state == S_IDLE && ddr_init_done && frame_done_any)
            burst_cnt <= 16'd0;
        else if (state == S_R && axi_rvalid && axi_rlast)
            burst_cnt <= burst_cnt + 1'b1;
    end

    // ====================== 行内突发计数 (用于 aruser_ap) ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            burst_in_line <= 4'd0;
        else if (state == S_IDLE && ddr_init_done && frame_done_any)
            burst_in_line <= 4'd0;
        else if (state == S_R && axi_rvalid && axi_rlast) begin
            if (burst_in_line == (BURST_PER_LINE - 1))
                burst_in_line <= 4'd0;
            else
                burst_in_line <= burst_in_line + 1'b1;
        end
    end

    // ====================== AXI AR 通道 (E8: ar_done 单次握手) ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n) begin
            axi_arvalid <= 1'b0;
            ar_done     <= 1'b0;
        end else if (state == S_AR && !ar_done) begin
            axi_arvalid <= 1'b1;
            if (axi_arvalid && axi_arready) begin
                axi_arvalid <= 1'b0;
                ar_done     <= 1'b1;
            end
        end else if (state != S_AR) begin
            ar_done <= 1'b0;
        end
    end

    assign axi_arlen      = AXI_ARLEN;
    assign axi_aruser_id  = 4'd0;
    assign axi_aruser_ap  = (burst_in_line == (BURST_PER_LINE - 1));  // 行尾/帧尾 auto-precharge

    // ====================== 整帧完成脉冲 ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n)
            read_done <= 1'b0;
        else if (state == S_R && axi_rvalid && axi_rlast
                 && (burst_cnt == (FRAME_BURST_CNT - 1)))
            read_done <= 1'b1;
        else
            read_done <= 1'b0;
    end

    // ====================== frame_consumed 脉冲 (通知写侧清除 frame_done) ======================
    always @(posedge clk_r or negedge rst_n) begin
        if (!rst_n) begin
            frame_consumed    <= 1'b0;
            consumed_frame_id <= 3'd0;
        end else if (state == S_R && axi_rvalid && axi_rlast
                     && (burst_cnt == (FRAME_BURST_CNT - 1))) begin
            frame_consumed    <= 1'b1;
            consumed_frame_id <= rd_frame_id_latched;
        end else begin
            frame_consumed <= 1'b0;
        end
    end

    // ====================== FIFO 写使能 (push 型: 无条件收每一个 rvalid) ======================
    assign fifo_wr_en   = (state == S_R) && axi_rvalid;
    assign fifo_wr_data = axi_rdata;

    // ====================== 读 FIFO 例化 ======================
    ddr_2_fifo u_ddr_2_fifo (
        .wr_clk         (clk_r),
        .wr_rst         (wr_rst),
        .wr_en          (fifo_wr_en),
        .wr_data        (fifo_wr_data),
        .wr_full        (fifo_wr_full),
        .wr_water_level (fifo_wr_water_level),
        .almost_full    (),
        .rd_clk         (clk_w),
        .rd_rst         (wr_rst),
        .rd_en          (rd_en),
        .rd_data        (data_out),
        .rd_empty       (rd_empty),
        .almost_empty   (almost_empty)
    );

endmodule
