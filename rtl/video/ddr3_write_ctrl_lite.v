// =============================================================================
// ddr3_write_ctrl_lite — 极简 DDR3 写控制器 (marker 驱动, core_clk 域)
// -----------------------------------------------------------------------------
// 新架构写侧：复用 fifo_2_ddr 异步 FIFO(16b写@pixclk / 128b读@core_clk, 自带 CDC+8:1打包),
// 逐 burst 从 FIFO 取 16 个 128-bit 字到本地缓冲, 凭首字低 16-bit 的 MAGIC_SOF 判帧头:
//   - 见 SOF → awaddr 复位到帧槽固定基址 (slot<<FRAME_SHIFT), 环形推进帧槽;
//   - 否则  → awaddr += 256 (线性递增, 复现刚性光栅布局, 与读侧算术寻址一致).
// 无命令 FIFO、无同步 CDC、无 SDP RAM ping-pong —— 边界信息全部 in-band 随数据流动.
//
// 帧头对齐保证: 前端 hdmi_in_detector 已确保 FIFO 首像素必是 SOF 且每行=1920(8的倍数),
// 故 SOF 永远落在某 burst 的首字首 lane → 帧头必对齐到帧槽基址.
//
// 硬约束(DDR3 IP 实测, 详见改造计划 §0):
//   C1 axi_wready 同拍锁存 → axi_wdata 组合直连 word_reg(预取), wready=1 才前移
//   C2 axi_wusero_last 定界 → 不数拍、不自造 wlast; 突发结束/帧完成全凭它
//   C3 无 B 通道 → frame_done 用 wusero_last 置位, 读侧 frame_consumed 清位
//
// 数据缓冲用本地 16×128 寄存器 buf(可随机重读) 而非直连 FIFO:
//   FIFO 是破坏性弹出且有 1 拍读延迟, wready 中途撤销(DDR refresh)时无法回读;
//   先把整 burst 读进 buf(确定性 16 拍), 再从 buf 组合供数, wready 撤销只需保持指针.
// =============================================================================
module ddr3_write_ctrl_lite #(
    parameter H_ACTIVE       = 1920,
    parameter V_ACTIVE       = 1080,
    parameter PIXEL_WIDTH    = 16,
    parameter AXI_DATA_WIDTH = 128,
    parameter AXI_ADDR_WIDTH = 28,
    parameter BURST_BEAT_CNT = 16,
    parameter RING_FRAMES    = 5,
    parameter FRAME_SHIFT    = 22,             // 原生地址槽步长 2^22 (x16 DDR 为 8 MiB)
    parameter [PIXEL_WIDTH-1:0] MAGIC_SOF = 16'h0001
)(
    input wire [4:0] protect_mask,
    input wire capture_ok,
    output reg [159:0] frame_ids,
    output wire write_active,
    input                              wr_clk,     // hdmi_pixclk (FIFO 写侧)
    input                              core_clk,   // DDR3 core_clk (FIFO 读侧 + AXI)
    input                              rst_n,
    input                              ddr_init_done,

    // ---- 前端整形像素流 (pixclk 域) ----
    input                              fifo_wr_en,
    input      [PIXEL_WIDTH-1:0]       fifo_wr_data,
    output                             fifo_almost_full,   // dbg: 溢出预警

    // ---- AXI4 写接口 (core_clk 域, Pango 简化 AXI) ----
    output reg [AXI_ADDR_WIDTH-1:0]    axi_awaddr,
    output                             axi_awuser_ap,
    output     [3:0]                   axi_awlen,
    output reg                         axi_awvalid,
    input                              axi_awready,
    output     [AXI_DATA_WIDTH-1:0]    axi_wdata,
    output     [AXI_DATA_WIDTH/8-1:0]  axi_wstrb,
    input                              axi_wready,
    input                              axi_wusero_last,

    // ---- 帧槽状态 (core_clk 域, 与 ddr3_read_ctrl 对接) ----
    output reg [RING_FRAMES-1:0]       frame_done,
    input                              frame_consumed,
    input      [2:0]                   consumed_frame_id,
    output     [2:0]                   wr_frame_id,

    // ---- 调试 ----
    output                             dbg_sof_seen
);

    // ======================== 派生常量 ========================
    localparam WORDS_PER_LINE = H_ACTIVE * PIXEL_WIDTH / AXI_DATA_WIDTH;         // 240
    localparam BURST_PER_LINE = WORDS_PER_LINE / BURST_BEAT_CNT;                 // 15
    localparam BURST_BYTES    = BURST_BEAT_CNT * (AXI_DATA_WIDTH / 8);           // 256

    // ======================== fifo_2_ddr 异步 FIFO ========================
    wire                        rd_en;
    wire [AXI_DATA_WIDTH-1:0]   rd_data;
    wire                        rd_empty;
    wire [9:0]                  rd_water_level;
    wire                        almost_empty;

    fifo_2_ddr u_fifo_2_ddr (
        .wr_clk         (wr_clk),
        .wr_rst         (~rst_n),
        .wr_en          (fifo_wr_en),
        .wr_data        (fifo_wr_data),
        .wr_full        (),
        .almost_full    (fifo_almost_full),
        .rd_clk         (core_clk),
        .rd_rst         (~rst_n),
        .rd_en          (rd_en),
        .rd_data        (rd_data),
        .rd_empty       (rd_empty),
        .rd_water_level (rd_water_level),
        .almost_empty   (almost_empty)
    );

    // ======================== FSM ========================
    localparam S_IDLE   = 3'd0;
    localparam S_LOAD   = 3'd1;   // 从 FIFO 读 16 字入 buf
    localparam S_AW     = 3'd2;
    localparam S_W_PRE  = 3'd3;   // 预装 beat0
    localparam S_W      = 3'd4;

    reg [2:0] state, next_state;

    // ======================== burst 本地缓冲 ========================
    reg [AXI_DATA_WIDTH-1:0] wbuf [0:BURST_BEAT_CNT-1];

    // ---- 读请求 / 捕获 (FIFO 1 拍读延迟: rd_en@T → rd_data@T+1) ----
    //   rd_en 组合: S_LOAD 且请求数<16 → 恰好拉高 16 拍(load_req 0..15).
    //   若把 rd_en 做成寄存器, 其值滞后 load_req 一拍会多弹 1 字(破坏 FIFO 顺序).
    reg [4:0] load_req;    // 已发读请求数 0..16
    reg [4:0] load_cap;    // 已捕获字数   0..16
    reg       rd_en_d1;    // rd_en 打 1 拍, 对齐返回数据

    assign rd_en = (state == S_LOAD) && (load_req < BURST_BEAT_CNT);

    wire load_done = (state == S_LOAD) && (load_cap == BURST_BEAT_CNT);

    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            load_req <= 5'd0;
            load_cap <= 5'd0;
            rd_en_d1 <= 1'b0;
        end else begin
            rd_en_d1 <= rd_en;
            if (state == S_LOAD) begin
                if (rd_en)
                    load_req <= load_req + 5'd1;
                // 捕获: rd_en_d1 对应上一拍 rd_en 的返回数据
                if (rd_en_d1 && (load_cap < BURST_BEAT_CNT)) begin
                    wbuf[load_cap[3:0]] <= rd_data;
                    load_cap <= load_cap + 5'd1;
                end
            end else begin
                // 离开 S_LOAD 时清零, 为下个 burst 准备
                load_req <= 5'd0;
                load_cap <= 5'd0;
            end
        end
    end

    // ---- 帧头判定 (首字低 16-bit) ----
    wire is_sof = (wbuf[0][PIXEL_WIDTH-1:0] == MAGIC_SOF);

    // ======================== 地址 / 帧槽 / ap ========================
    reg [2:0]  slot;            // 当前帧槽 0..RING_FRAMES-1
    reg [3:0]  burst_in_line;   // 0..BURST_PER_LINE-1
    reg        have_prev;       // 是否已写过至少一帧(用于 frame_done 前一帧置位)

    assign axi_awuser_ap = (burst_in_line == (BURST_PER_LINE - 1));  // 行尾 burst = auto-precharge
    assign axi_awlen     = BURST_BEAT_CNT - 1;                       // 15
    assign wr_frame_id   = slot;

    reg [2:0] slot_next;
    reg free_slot,drop_frame,invalid_frame;
    reg [31:0] sequence_id,active_id;
    reg [15:0] written_bursts;
    localparam FRAME_BURSTS=H_ACTIVE*V_ACTIVE*PIXEL_WIDTH/8/(AXI_DATA_WIDTH/8*BURST_BEAT_CNT);
    integer search,choice;
    always @(*) begin
        free_slot=0;slot_next=0;
        for(search=1;search<=RING_FRAMES;search=search+1)begin
            choice=slot+search;
            if(choice>=RING_FRAMES)choice=choice-RING_FRAMES;
            if(!free_slot && !protect_mask[choice])begin
                free_slot=1;slot_next=choice[2:0];
            end
        end
    end
    assign write_active=have_prev && !drop_frame;
    always @(posedge core_clk or negedge rst_n)begin
        if(!rst_n)begin drop_frame<=1;invalid_frame<=1;written_bursts<=0;sequence_id<=0;active_id<=0;end
        else begin
            if(!capture_ok)invalid_frame<=1;
            if(state==S_W && axi_wready && axi_wusero_last)written_bursts<=written_bursts+1'b1;
            if(load_done && is_sof)begin
                drop_frame<=!free_slot;invalid_frame<=!capture_ok;written_bursts<=0;
                sequence_id<=sequence_id+1'b1;active_id<=sequence_id;
            end
        end
    end
    // 帧槽基址: slot_next 置于 bit[FRAME_SHIFT +: 3] (拼接避免小位宽左移被截断为0)
    wire [AXI_ADDR_WIDTH-1:0] slot_base = {slot_next, {FRAME_SHIFT{1'b0}}};

    // load_done 那一拍: 更新地址/帧槽/行内 burst 号
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awaddr    <= {AXI_ADDR_WIDTH{1'b0}};
            slot          <= (RING_FRAMES - 1);   // 首个 SOF 推进到槽 0 → 帧头写 0x000000
            burst_in_line <= 4'd0;
            have_prev     <= 1'b0;
        end else if (load_done) begin
            if (is_sof) begin
                if(free_slot) slot <= slot_next;
                axi_awaddr    <= slot_base;
                burst_in_line <= 4'd0;
                have_prev     <= free_slot;
            end else begin
                axi_awaddr    <= axi_awaddr + BURST_BYTES;
                burst_in_line <= (burst_in_line == (BURST_PER_LINE - 1))
                                 ? 4'd0 : burst_in_line + 4'd1;
            end
        end
    end

    assign dbg_sof_seen = have_prev;

    // ======================== FSM 转移 ========================
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    reg aw_done;

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:  if (ddr_init_done && (rd_water_level >= BURST_BEAT_CNT))
                         next_state = S_LOAD;
            S_LOAD:  if (load_cap == BURST_BEAT_CNT)
                         next_state = ((is_sof && !free_slot) || (!is_sof && drop_frame)) ? S_IDLE:S_AW;
            S_AW:    if (axi_awvalid && axi_awready)
                         next_state = S_W_PRE;
            S_W_PRE: next_state = S_W;
            S_W:     if (axi_wusero_last)     // C2: IP 告知本突发最后一拍
                         next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    // ---- awvalid + aw_done (E8: 握手后锁存, 不重复拉高) ----
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awvalid <= 1'b0;
            aw_done     <= 1'b0;
        end else if (state == S_AW && !aw_done) begin
            axi_awvalid <= 1'b1;
            if (axi_awvalid && axi_awready) begin
                axi_awvalid <= 1'b0;
                aw_done     <= 1'b1;
            end
        end else if (state != S_AW) begin
            axi_awvalid <= 1'b0;
            aw_done     <= 1'b0;
        end
    end

    // ======================== 供数: word_reg 预取 (C1) ========================
    reg [AXI_DATA_WIDTH-1:0] word_reg;
    reg [4:0]                rd_idx;    // buf 下一取字 0..16

    assign axi_wdata = word_reg;                       // C1: 组合直连预取寄存器
    assign axi_wstrb = {(AXI_DATA_WIDTH/8){1'b1}};

    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            word_reg <= {AXI_DATA_WIDTH{1'b0}};
            rd_idx   <= 5'd0;
        end else begin
            case (state)
                S_AW: begin
                    rd_idx   <= 5'd0;
                end
                S_W_PRE: begin
                    word_reg <= wbuf[0];               // 预装 beat0
                    rd_idx   <= 5'd1;                  // 下一拍取 beat1
                end
                S_W: begin
                    if (axi_wready) begin              // IP 本拍锁走 word_reg → 前移
                        word_reg <= wbuf[rd_idx[3:0]];
                        rd_idx   <= rd_idx + 5'd1;
                    end
                    // wready=0: 保持, 不丢数(C1)
                end
                default: ;
            endcase
        end
    end

    // ======================== 帧槽完成管理 (无 B 通道) ========================
    // 前一帧完成的判据: 收到下一帧 SOF burst 时(load_done && is_sof),
    // 说明上一帧全部 burst 的 wusero_last 都已在此前 S_W 回来 → 上一帧安全落盘.
    // 新增精确 burst 数和输入形状检查；不完整帧不发布给读侧。
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_done <= {RING_FRAMES{1'b0}};frame_ids<=0;
        end else begin
            if (load_done && is_sof)begin
                if(have_prev && !drop_frame && !invalid_frame && written_bursts==FRAME_BURSTS)begin
                    frame_done[slot]<=1;frame_ids[slot*32 +:32]<=active_id;
                end
                if(free_slot)frame_done[slot_next]<=0;
            end
            if (frame_consumed)
                frame_done[consumed_frame_id] <= 1'b0;
        end
    end

endmodule
