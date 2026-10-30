// =============================================================================
// hdmi_in_detector — HDMI 前端检测/整形模块 (pixclk 域)
// -----------------------------------------------------------------------------
// 新架构核心前端：把杂乱的 HDMI 同步流整理成"每行严格 1920 像素、每帧严格从帧头
// 开始"的干净像素流，并在帧头/行头/行尾/帧尾四个边界像素上覆盖保留值(magic)。
// 下游(写控制器)只凭这些 in-band 标记 + 固定地址即可对齐，无需命令 FIFO / 同步 CDC。
//
// 关键保证(满足用户硬性要求 "帧头一定落在帧头位置，特别是第一帧")：
//   1. 首帧保护：上电后必须见到 SKIP_FRAMES 个 VS 边沿才放行(wr_enable)，
//      因此 FIFO 收到的第一个像素必然是某个真正帧头，永不含半帧残缺数据。
//   2. 放行后逐帧以 VS 边沿把 out_line 归零，第一行(out_line==0)首像素 = MAGIC_SOF，
//      写侧凭 MAGIC_SOF 把该帧写到固定地址(000000)。
//   3. 每行强制输出 OUT_PIX(=1920) 像素(不足则补黑、超出则丢弃尾部)，
//      1920 是 8 的整数倍 → FIFO 8:1 打包永远对齐，SOF 永远落在 burst 边界。
//
// 值保留(value reservation)：真实像素若撞上 4 个 magic 值之一，前端直接涂黑(CLAMP)，
// 使 16-bit 标记无歧义。代价 = 极少数像素轻微失真(用户已确认"一两行几乎不可见")。
// =============================================================================
module hdmi_in_detector #(
    parameter H_ACTIVE     = 1920,
    parameter V_ACTIVE     = 1080,
    parameter OUT_PIX      = 1920,             // 每行输出像素数(补齐/截断到此, 必须为8的倍数)
    parameter PIXEL_WIDTH  = 16,
    parameter VS_POL       = 1,                // VS 极性 (1=高有效)
    parameter HS_POL       = 1,
    parameter DE_POL       = 1,
    parameter SKIP_FRAMES  = 4,                // 首帧保护: 放行前需见到的 VS 数(多跳几帧更稳)
    // ---- 边界标记 magic 值(保留, 真实像素撞车则 CLAMP) ----
    parameter [PIXEL_WIDTH-1:0] MAGIC_SOF  = 16'h0001,   // 帧头 (line0 pix0)
    parameter [PIXEL_WIDTH-1:0] MAGIC_LINE = 16'h0002,   // 行头 (pix0, line>0)
    parameter [PIXEL_WIDTH-1:0] MAGIC_LEND = 16'h0003,   // 行尾 (last pix, 非末行)
    parameter [PIXEL_WIDTH-1:0] MAGIC_FEND = 16'h0004,   // 帧尾 (last pix, 末行)
    parameter [PIXEL_WIDTH-1:0] CLAMP_VAL  = 16'h0000    // 撞车像素涂黑
)(
    input                          clk,        // hdmi_pixclk
    input                          rst_n,

    // ---- HDMI 原始输入(原始极性) ----
    input                          hdmi_vs,
    input                          hdmi_hs,
    input                          hdmi_de,
    input      [PIXEL_WIDTH-1:0]   hdmi_data,  // RGB565 像素

    // ---- 整形后输出 → fifo_2_ddr 写侧 ----
    output reg                     fifo_wr_en,
    output reg [PIXEL_WIDTH-1:0]   fifo_wr_data,

    // ---- 调试 ----
    output wire                    wr_enable,  // 首帧保护已放行
    output reg [10:0]              out_line    // 当前输出行号 0..V_ACTIVE-1
);

    // -------------------------------------------------------------------------
    // 极性归一化 + 3FF 同步 (VS / DE ; HS 仅同步不参与计数, 避免 HS 毛刺误清)
    // -------------------------------------------------------------------------
    wire vs_i = VS_POL ? hdmi_vs : ~hdmi_vs;
    wire de_i = DE_POL ? hdmi_de : ~hdmi_de;

    reg vs_s1, vs_s2, vs_s3;
    reg de_s1, de_s2, de_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {vs_s3, vs_s2, vs_s1} <= 3'b000;
            {de_s3, de_s2, de_s1} <= 3'b000;
        end else begin
            {vs_s3, vs_s2, vs_s1} <= {vs_s2, vs_s1, vs_i};
            {de_s3, de_s2, de_s1} <= {de_s2, de_s1, de_i};
        end
    end

    wire vs_edge   =  vs_s2 & ~vs_s3;          // VS 上升沿 = 新帧锚点
    wire de_rising =  de_s2 & ~de_s3;          // DE 上升沿 = 行起始

    // 像素数据对齐到 de_s2 (DE 延迟 2 拍) → 数据同延迟 2 拍
    reg [PIXEL_WIDTH-1:0] data_d1, data_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_d1 <= {PIXEL_WIDTH{1'b0}};
            data_d2 <= {PIXEL_WIDTH{1'b0}};
        end else begin
            data_d1 <= hdmi_data;
            data_d2 <= data_d1;
        end
    end

    // -------------------------------------------------------------------------
    // 首帧保护: 见过 SKIP_FRAMES 个 VS 边沿后才放行 (与 frame_sync_proc 同机制)
    //   ⚠漏洞: 仅以 vs_edge 为判据, 无消抖; VS 毛刺可能提前放行 → 首帧撕裂.
    //           3FF 只滤单拍亚稳态, 滤不掉真实窄毛刺. 必要时增大 SKIP_FRAMES.
    // -------------------------------------------------------------------------
    reg [2:0] vs_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vs_count <= 3'd0;
        else if (vs_edge)
            vs_count <= (vs_count >= SKIP_FRAMES) ? vs_count : vs_count + 3'd1;
    end
    assign wr_enable = (vs_count >= SKIP_FRAMES);

    // -------------------------------------------------------------------------
    // 单计数器行输出引擎
    //   de_rising(放行后) 触发一行输出: emit_cnt 0..OUT_PIX-1 每拍输出 1 像素,
    //   DE 高→真实像素, DE 低(消隐)→补黑; 满 OUT_PIX 停止, 等下一 de_rising.
    //   → 每行严格 OUT_PIX 像素, 与 HDMI 实际 1919/1920 无关.
    // -------------------------------------------------------------------------
    reg        emitting;
    reg [10:0] emit_cnt;                       // 0..OUT_PIX-1

    wire start_line = de_rising && wr_enable && !emitting;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emitting <= 1'b0;
            emit_cnt <= 11'd0;
            out_line <= 11'd0;
        end else begin
            // 新帧: 行号归零(帧头锚点). vs_edge 优先级高于行完成递增.
            if (vs_edge)
                out_line <= 11'd0;

            if (start_line) begin
                emitting <= 1'b1;
                emit_cnt <= 11'd0;
            end else if (emitting) begin
                if (emit_cnt == (OUT_PIX - 1)) begin
                    emitting <= 1'b0;
                    // 完成一行 → 行号递增(除非本拍 vs_edge 已归零). 末行处保持, 等 vs.
                    if (!vs_edge && (out_line != (V_ACTIVE - 1)))
                        out_line <= out_line + 11'd1;
                end else begin
                    emit_cnt <= emit_cnt + 11'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 像素/标记选择 (组合) + FIFO 写
    //   emitting=1 时本拍输出 index=emit_cnt:
    //     首像素(0)       → 帧头/行头 magic
    //     尾像素(OUT_PIX-1)→ 帧尾/行尾 magic
    //     其余            → DE 高: 真实(撞车涂黑); DE 低: 补黑
    // -------------------------------------------------------------------------
    wire real_hit = (data_d2 == MAGIC_SOF) || (data_d2 == MAGIC_LINE)
                 || (data_d2 == MAGIC_LEND) || (data_d2 == MAGIC_FEND);
    wire [PIXEL_WIDTH-1:0] real_val = real_hit ? CLAMP_VAL : data_d2;
    wire [PIXEL_WIDTH-1:0] body_val = de_s2 ? real_val : CLAMP_VAL;

    wire [PIXEL_WIDTH-1:0] head_val = (out_line == 11'd0) ? MAGIC_SOF : MAGIC_LINE;
    wire [PIXEL_WIDTH-1:0] tail_val = (out_line == (V_ACTIVE - 1)) ? MAGIC_FEND : MAGIC_LEND;

    wire [PIXEL_WIDTH-1:0] pix_sel  = (emit_cnt == 11'd0)            ? head_val :
                                      (emit_cnt == (OUT_PIX - 1))    ? tail_val :
                                                                       body_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_en   <= 1'b0;
            fifo_wr_data <= {PIXEL_WIDTH{1'b0}};
        end else begin
            fifo_wr_en   <= emitting;          // emitting 每拍写 1 像素
            fifo_wr_data <= pix_sel;
        end
    end

endmodule
