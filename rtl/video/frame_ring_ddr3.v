// =============================================================================
// frame_ring_ddr3 — 新架构(marker 驱动)顶层封装, frame_pingpong_ddr3 的替代品
// -----------------------------------------------------------------------------
// 对主工程呈现与 frame_pingpong_ddr3 一致的"写 16bit@pixclk / 读 128bit@pclk_div2"
// 接口, 内部用 DDR3 环形帧缓冲解耦 HDMI 生产与 PCIe 消费。
//
// 数据通路:
//   hdmi_in_detector (pixclk)  ── 整形/补齐1920/注入 magic 边界标记 ──▶
//   ddr3_write_ctrl_lite       ── 内含 fifo_2_ddr(CDC+8:1打包), 凭 SOF 复位帧槽基址 ──▶
//   DDR3 IP  (AXI AW/W 写口)
//   DDR3 IP  (AXI AR/R 读口)   ──▶ ddr3_read_ctrl (内含 ddr_2_fifo) ──▶ 128bit 用户读
//
// 相对 frame_pingpong_ddr3 的简化:
//   1. 无 VS CDC: 帧对齐全部下沉到 hdmi_in_detector(pixclk 域, 首帧保护 SKIP_FRAMES)。
//   2. 无 dma_start CDC: 读侧自治 —— 见 frame_done 即整帧读出并 frame_consumed 清位。
//   3. 无命令 FIFO / SDP RAM ping-pong: 帧边界随数据 in-band 流动。
//   4. 写读控制器同在 core_clk 域, frame_done/frame_consumed 握手无需 CDC。
//   5. M2 新增 CPU/视频共享仲裁，AW/W 和 AR/R 分别锁定到突发完成。
//
// 接口保留了 frame_pingpong_ddr3 的端口名以便主工程平替; 新架构中不再需要的端口
// (clr / wr_en / dma_start) 保留但内部未用, 见各处标注。
// =============================================================================
module frame_ring_ddr3 #(
    parameter integer ENABLE_PCIE_READER = 1,
    parameter MEM_ROW_WIDTH    = 15,
    parameter MEM_COLUMN_WIDTH = 10,
    parameter MEM_BANK_WIDTH   = 3,
    parameter MEM_DQ_WIDTH     = 16,
    parameter MEM_DQS_WIDTH    = 2,
    parameter MEM_DM_WIDTH     = 2,

    parameter PIXEL_WIDTH      = 16,
    parameter H_ACTIVE         = 1920,
    parameter V_ACTIVE         = 1080,
    parameter AXI_DATA_WIDTH   = 128,
    parameter AXI_ADDR_WIDTH   = 28,
    parameter BURST_BEAT_CNT   = 16,
    parameter RING_FRAMES      = 5,
    parameter FRAME_SHIFT      = 22,           // 原生地址槽步长 2^22，保留参考写读布局
    parameter [PIXEL_WIDTH-1:0] MAGIC_SOF = 16'h0001
)(
    input wire [27:0] tensor_awaddr,
    input wire tensor_awvalid,tensor_awap,tensor_fault,
    input wire [3:0] tensor_awlen,tensor_awid,
    input wire [127:0] tensor_wdata,
    input wire [15:0] tensor_wstrb,
    output wire tensor_awready,tensor_wready,tensor_wlast,
    output wire [3:0] tensor_wid,
    input wire [4:0] tensor_hold,
    output wire [31:0] source_next_id,
    output wire source_ready,raw_begin,raw_accepted,raw_end,raw_end_ok,
    output wire [31:0] raw_begin_id,raw_end_id,
    output wire [2:0] raw_begin_slot,raw_end_slot,
    input wire [27:0] cpu_awaddr,cpu_araddr,
    input wire cpu_awvalid,cpu_arvalid,cpu_awap,cpu_arap,
    input wire [3:0] cpu_awlen,cpu_arlen,cpu_awid,cpu_arid,
    output wire cpu_awready,cpu_arready,cpu_wready,cpu_wlast,cpu_rvalid,cpu_rlast,
    output wire [3:0] cpu_wid,cpu_rid,
    input wire [127:0] cpu_wdata,
    input wire [15:0] cpu_wstrb,
    output wire [127:0] cpu_rdata,
    input wire [4:0] hold_mask,
    input wire stream_ok,
    output wire [4:0] available,
    output wire [159:0] frame_ids,
    output wire [2:0] write_slot,
    output wire write_active,shared_fault,

    // ======================== 时钟与复位 ========================
    input                           sys_clk,       // 25MHz -> DDR3 ref_clk
    input                           sys_rst_n,
    input                           clr,           // 保留(新架构未用)
    output                          core_clk,      // DDR3 IP 输出(~131.25MHz), 导出
    output                          ddr_init_done,
    output                          ddr_pll_lock,
    output                          ddr_init_fail,

    // ======================== 诊断(粘滞标志, core_clk 域) ========================
    output                          dbg_vs_seen,      // 已写过至少一帧(SOF 已见)
    output                          dbg_wr_done_seen, // AXI 写突发曾完成(wready & wlast)
    output                          dbg_read_started, // 读 FSM 曾起步
    output                          dbg_frame_done,   // 曾完成一整帧读
    output                          dbg_rd_fifo_ovf,  // 保留(新架构未跟踪)
    output                          dbg_sof_bad,      // 保留(读侧不再扫描 SOF)
    output                          dbg_wr_sof_bad,   // 保留(写侧由构造保证 SOF 坐基址)

    // ======================== 写用户侧 (hdmi_pixclk) ========================
    input                           wr_clk,        // hdmi_pixclk
    input  [PIXEL_WIDTH-1:0]        wr_data,       // 16bit 像素 = hdmi_data
    input                           wr_en,         // 保留(detector 以 de 自门控, 未用)
    input                           vs,            // hdmi_vs (原始极性)
    input                           de,            // hdmi_de (原始极性)
    output                          wr_almost_full,

    // ======================== 读用户侧 (pclk_div2) ========================
    input                           rd_clk,        // pclk_div2
    input                           dma_start,     // 保留(读侧自治, 未用)
    output [AXI_DATA_WIDTH-1:0]     rd_data,       // 128bit
    input                           rd_en,
    output                          rd_empty,
    output                          rd_almost_empty,
    output                          read_busy,
    output                          read_done,

    // ======================== 状态(调试可选) ========================
    output                          frame_valid,   // 有帧可读 = |frame_done
    output [2:0]                    wr_slot,        // 当前写帧槽

    // ======================== DDR3 物理接口 ========================
    output                          mem_rst_n,
    output                          mem_ck,
    output                          mem_ck_n,
    output                          mem_cke,
    output                          mem_ras_n,
    output                          mem_cas_n,
    output                          mem_we_n,
    output                          mem_odt,
    output [MEM_ROW_WIDTH-1:0]      mem_a,
    output [MEM_BANK_WIDTH-1:0]     mem_ba,
    inout  [MEM_DQS_WIDTH-1:0]      mem_dqs,
    inout  [MEM_DQS_WIDTH-1:0]      mem_dqs_n,
    inout  [MEM_DQ_WIDTH-1:0]       mem_dq,
    output [MEM_DM_WIDTH-1:0]       mem_dm
);

    // ======================== 内部时钟 ========================
    wire core_clk_i;
    assign core_clk = core_clk_i;

    // ======================== 前端整形像素流 (pixclk 域) ========================
    wire                    det_wr_en;
    wire [PIXEL_WIDTH-1:0]  det_wr_data;

    // ======================== 帧槽握手 (core_clk 域, 无 CDC) ========================
    wire [RING_FRAMES-1:0]  frame_done;
    wire [4:0] reader_hold;
    (* ASYNC_REG="TRUE" *) reg stream_meta,stream_sync;
    always @(posedge core_clk_i or negedge sys_rst_n)
        if(!sys_rst_n)begin stream_meta<=0;stream_sync<=0;end
        else begin stream_meta<=stream_ok;stream_sync<=stream_meta;end
    assign available=frame_done;
    assign write_slot=wr_frame_id;
    wire                    frame_consumed;
    wire [2:0]              consumed_frame_id;
    wire [2:0]              wr_frame_id;
    wire                    dbg_sof_seen;

    assign frame_valid = |frame_done;
    assign wr_slot     = wr_frame_id;

    // ======================== AXI4 写通道 (write_ctrl <-> ddr3) ========================
    wire [AXI_ADDR_WIDTH-1:0]    w_awaddr;
    wire                         w_awuser_ap;
    wire [3:0]                   w_awlen;
    wire                         w_awvalid;
    wire                         w_awready;
    wire [AXI_DATA_WIDTH-1:0]    w_wdata;
    wire [AXI_DATA_WIDTH/8-1:0]  w_wstrb;
    wire                         w_wready;
    wire                         w_wlast;   // = IP axi_wusero_last

    // ======================== AXI4 读通道 (read_ctrl <-> ddr3) ========================
    wire [AXI_ADDR_WIDTH-1:0]    r_araddr;
    wire                         r_aruser_ap;
    wire [3:0]                   r_aruser_id;
    wire [3:0]                   r_arlen;
    wire                         r_arvalid;
    wire                         r_arready;
    wire [AXI_DATA_WIDTH-1:0]    r_rdata;
    wire [3:0]                   r_rid;
    wire                         r_rlast;
    wire                         r_rvalid;

    // ======================== 前端: HDMI 整形/标记注入 ========================
    hdmi_in_detector #(
        .H_ACTIVE     ( H_ACTIVE     ),
        .V_ACTIVE     ( V_ACTIVE     ),
        .OUT_PIX      ( H_ACTIVE     ),
        .PIXEL_WIDTH  ( PIXEL_WIDTH  ),
        .MAGIC_SOF    ( MAGIC_SOF    )
    ) u_detector (
        .clk          ( wr_clk       ),
        .rst_n        ( sys_rst_n    ),
        .hdmi_vs      ( vs           ),
        .hdmi_hs      ( 1'b0         ),   // detector 内部不使用 HS
        .hdmi_de      ( de           ),
        .hdmi_data    ( wr_data      ),
        .fifo_wr_en   ( det_wr_en    ),
        .fifo_wr_data ( det_wr_data  ),
        .wr_enable    ( source_ready ),
        .out_line     (              )
    );

    // ======================== 写控制器: FIFO -> DDR3 (含 fifo_2_ddr) ========================
    ddr3_write_ctrl_lite #(
        .H_ACTIVE       ( H_ACTIVE       ),
        .V_ACTIVE       ( V_ACTIVE       ),
        .PIXEL_WIDTH    ( PIXEL_WIDTH    ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .BURST_BEAT_CNT ( BURST_BEAT_CNT ),
        .RING_FRAMES    ( RING_FRAMES    ),
        .FRAME_SHIFT    ( FRAME_SHIFT    ),
        .MAGIC_SOF      ( MAGIC_SOF      )
    ) u_write_ctrl (
        .protect_mask(hold_mask|reader_hold|tensor_hold),.capture_ok(stream_sync),
        .frame_ids(frame_ids),.write_active(write_active),
        .source_next_id(source_next_id),.source_fault(video_source_fault),
        .frame_begin(raw_begin),.frame_begin_accepted(raw_accepted),
        .frame_begin_id(raw_begin_id),.frame_begin_slot(raw_begin_slot),
        .frame_end(raw_end),.frame_end_ok(raw_end_ok),.frame_end_id(raw_end_id),.frame_end_slot(raw_end_slot),
        .wr_clk           ( wr_clk         ),
        .core_clk         ( core_clk_i     ),
        .rst_n            ( sys_rst_n      ),
        .ddr_init_done    ( ddr_init_done  ),

        .fifo_wr_en       ( det_wr_en      ),
        .fifo_wr_data     ( det_wr_data    ),
        .fifo_almost_full ( wr_almost_full ),

        .axi_awaddr       ( w_awaddr       ),
        .axi_awuser_ap    ( w_awuser_ap    ),
        .axi_awlen        ( w_awlen        ),
        .axi_awvalid      ( w_awvalid      ),
        .axi_awready      ( w_awready      ),
        .axi_wdata        ( w_wdata        ),
        .axi_wstrb        ( w_wstrb        ),
        .axi_wready       ( w_wready       ),
        .axi_wusero_last  ( w_wlast        ),

        .frame_done       ( frame_done        ),
        .frame_consumed   ( frame_consumed    ),
        .consumed_frame_id( consumed_frame_id ),
        .wr_frame_id      ( wr_frame_id       ),
        .dbg_sof_seen     ( dbg_sof_seen      )
    );

    // ======================== 读控制器: DDR3 -> FIFO (含 ddr_2_fifo, 自治) ========================
    generate if(ENABLE_PCIE_READER)begin: g_reader
    ddr3_read_ctrl #(
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .BURST_BEAT_CNT ( BURST_BEAT_CNT ),
        .PIXEL_WIDTH    ( PIXEL_WIDTH    ),
        .H_ACTIVE       ( H_ACTIVE       ),
        .V_ACTIVE       ( V_ACTIVE       ),
        .FRAME_SHIFT    ( FRAME_SHIFT    )
    ) u_read_ctrl (
        .protect_mask(reader_hold),
        .rst_n            ( sys_rst_n      ),
        .clk_w            ( rd_clk         ),
        .clk_r            ( core_clk_i     ),

        .frame_done       ( frame_done        ),
        .frame_consumed   ( frame_consumed    ),
        .consumed_frame_id( consumed_frame_id ),

        .ddr_init_done    ( ddr_init_done  ),
        .read_busy        ( read_busy      ),
        .read_done        ( read_done      ),

        .data_out         ( rd_data        ),
        .rd_en            ( rd_en          ),
        .rd_empty         ( rd_empty       ),
        .almost_empty     ( rd_almost_empty),

        .axi_araddr       ( r_araddr       ),
        .axi_aruser_ap    ( r_aruser_ap    ),
        .axi_aruser_id    ( r_aruser_id    ),
        .axi_arlen        ( r_arlen        ),
        .axi_arvalid      ( r_arvalid      ),
        .axi_arready      ( r_arready      ),

        .axi_rdata        ( r_rdata        ),
        .axi_rlast        ( r_rlast        ),
        .axi_rvalid       ( r_rvalid       )
    );
    end else begin: g_no_reader
        // No RK means the PCIe read clock may not exist. Do not fill its FIFO,
        // acquire a reader lease or issue video AR requests in local mode.
        assign reader_hold=0;
        assign frame_consumed=0;assign consumed_frame_id=0;
        assign read_busy=0;assign read_done=0;
        assign rd_data=0;assign rd_empty=1;assign rd_almost_empty=1;
        assign r_araddr=0;assign r_aruser_ap=0;assign r_aruser_id=0;
        assign r_arlen=0;assign r_arvalid=0;
    end endgenerate

    // ======================== 诊断粘滞标志 (core_clk 域) ========================
    reg wr_done_seen_r, read_started_r, frame_done_seen_r;
    always @(posedge core_clk_i or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            wr_done_seen_r    <= 1'b0;
            read_started_r    <= 1'b0;
            frame_done_seen_r <= 1'b0;
        end else begin
            if (w_wready && w_wlast) wr_done_seen_r    <= 1'b1;
            if (read_busy)           read_started_r    <= 1'b1;
            if (read_done)           frame_done_seen_r <= 1'b1;
        end
    end
    assign dbg_vs_seen      = dbg_sof_seen;      // 已写过至少一帧
    assign dbg_wr_done_seen = wr_done_seen_r;
    assign dbg_read_started = read_started_r;
    assign dbg_frame_done   = frame_done_seen_r;
    assign dbg_rd_fifo_ovf  = 1'b0;              // 新架构未跟踪
    assign dbg_sof_bad      = 1'b0;              // 读侧不再扫描
    assign dbg_wr_sof_bad   = 1'b0;              // 写侧由构造保证 SOF 坐基址

    // ======================== DDR3 IP ========================

    wire [27:0] m_awaddr,m_araddr;
    wire m_awap,m_arap,m_awvalid,m_arvalid,m_awready,m_arready,m_wready,m_wlast,m_rvalid,m_rlast;
    wire [3:0] m_awlen,m_arlen,m_awid,m_arid,m_wid,m_rid;
    wire [127:0] m_wdata,m_rdata;
    wire [15:0] m_wstrb;
    wire [1:0] s_awready,s_arready,s_wready,s_wlast,s_rvalid,s_rlast;
    wire [7:0] s_wid,s_rid;
    wire [255:0] s_rdata;
    wire arb_error;
    wire range_error;
    wire video_source_fault,client_fault;
    wire [27:0] client_awaddr,client_araddr;
    wire client_awvalid,client_arvalid,client_awap,client_arap;
    wire [3:0] client_awlen,client_arlen,client_awid,client_arid;
    wire [127:0] client_wdata;
    wire [15:0] client_wstrb;
    wire [1:0] c_awready,c_arready,c_wready,c_wlast,c_rvalid,c_rlast;
    wire [7:0] c_wid,c_rid;
    wire [255:0] c_rdata;
    wire [1:0] cpu_qualified;
    ddr_region_check u_region_check(.clk(core_clk_i),.rst_n(sys_rst_n),
        .valid({cpu_arvalid,cpu_awvalid}),.accepted({cpu_arvalid&&cpu_arready,cpu_awvalid&&cpu_awready}),
        .address({cpu_araddr,cpu_awaddr}),.length({cpu_arlen,cpu_awlen}),
        .qualified(cpu_qualified),.fault(range_error));
    assign shared_fault=arb_error|range_error|video_source_fault|client_fault|tensor_fault;
    // The reference video port remains requester 0 of the outer arbiter. CPU
    // and tensor writes share requester 1, retaining complete-burst ownership.
    ddr_native_arbiter u_client_arbiter(
        .clk(core_clk_i),.rst_n(sys_rst_n),
        .s_awaddr({tensor_awaddr,cpu_awaddr+28'h2000000}),.s_araddr({28'b0,cpu_araddr+28'h2000000}),
        .s_awvalid({tensor_awvalid,cpu_qualified[0]}),.s_arvalid({1'b0,cpu_qualified[1]}),
        .s_awap({tensor_awap,cpu_awap}),.s_arap({1'b0,cpu_arap}),
        .s_awlen({tensor_awlen,cpu_awlen}),.s_arlen({4'b0,cpu_arlen}),
        .s_awid({tensor_awid,cpu_awid}),.s_arid({4'b0,cpu_arid}),
        .s_awready(c_awready),.s_arready(c_arready),.s_wready(c_wready),.s_wlast(c_wlast),
        .s_rvalid(c_rvalid),.s_rlast(c_rlast),.s_wid(c_wid),.s_rid(c_rid),
        .s_wdata({tensor_wdata,cpu_wdata}),.s_wstrb({tensor_wstrb,cpu_wstrb}),.s_rdata(c_rdata),
        .m_awaddr(client_awaddr),.m_araddr(client_araddr),.m_awvalid(client_awvalid),.m_arvalid(client_arvalid),
        .m_awap(client_awap),.m_arap(client_arap),.m_awlen(client_awlen),.m_arlen(client_arlen),
        .m_awid(client_awid),.m_arid(client_arid),.m_awready(s_awready[1]),.m_arready(s_arready[1]),
        .m_wready(s_wready[1]),.m_wlast(s_wlast[1]),.m_rvalid(s_rvalid[1]),.m_rlast(s_rlast[1]),
        .m_wid(s_wid[7:4]),.m_rid(s_rid[7:4]),.m_wdata(client_wdata),.m_wstrb(client_wstrb),
        .m_rdata(s_rdata[255:128]),.fault(client_fault));
    assign {tensor_awready,cpu_awready}=c_awready;
    assign cpu_arready=c_arready[0];
    assign {tensor_wready,cpu_wready}=c_wready;
    assign {tensor_wlast,cpu_wlast}=c_wlast;
    assign tensor_wid=c_wid[7:4];assign cpu_wid=c_wid[3:0];
    assign cpu_rid=c_rid[3:0];assign cpu_rvalid=c_rvalid[0];assign cpu_rlast=c_rlast[0];
    assign cpu_rdata=c_rdata[127:0];
    ddr_native_arbiter u_arbiter (
        .clk(core_clk_i),.rst_n(sys_rst_n),
        .s_awaddr({client_awaddr,w_awaddr}),.s_araddr({client_araddr,r_araddr}),
        .s_awvalid({client_awvalid,w_awvalid}),.s_arvalid({client_arvalid,r_arvalid}),
        .s_awap({client_awap,w_awuser_ap}),.s_arap({client_arap,r_aruser_ap}),
        .s_awlen({client_awlen,w_awlen}),.s_arlen({client_arlen,r_arlen}),
        .s_awid({client_awid,4'd0}),.s_arid({client_arid,r_aruser_id}),
        .s_awready(s_awready),.s_arready(s_arready),.s_wready(s_wready),.s_wlast(s_wlast),
        .s_rvalid(s_rvalid),.s_rlast(s_rlast),.s_wid(s_wid),.s_rid(s_rid),
        .s_wdata({client_wdata,w_wdata}),.s_wstrb({client_wstrb,w_wstrb}),.s_rdata(s_rdata),
        .m_awaddr(m_awaddr),.m_araddr(m_araddr),.m_awvalid(m_awvalid),.m_arvalid(m_arvalid),
        .m_awap(m_awap),.m_arap(m_arap),.m_awlen(m_awlen),.m_arlen(m_arlen),
        .m_awid(m_awid),.m_arid(m_arid),.m_awready(m_awready),.m_arready(m_arready),
        .m_wready(m_wready),.m_wlast(m_wlast),.m_rvalid(m_rvalid),.m_rlast(m_rlast),
        .m_wid(m_wid),.m_rid(m_rid),.m_wdata(m_wdata),.m_wstrb(m_wstrb),.m_rdata(m_rdata),.fault(arb_error)
    );
    assign w_awready=s_awready[0];assign r_arready=s_arready[0];
    assign w_wready=s_wready[0];assign w_wlast=s_wlast[0];
    assign r_rvalid=s_rvalid[0];assign r_rlast=s_rlast[0];
    assign r_rid=s_rid[3:0];assign r_rdata=s_rdata[127:0];
    ddr3 u_ddr3 (
        .ref_clk                ( sys_clk          ),
        .resetn                 ( sys_rst_n        ),
        .core_clk               ( core_clk_i       ),
        .pll_lock               ( ddr_pll_lock     ),
        .phy_pll_lock           (                  ),
        .gpll_lock              (                  ),
        .rst_gpll_lock          (                  ),
        .ddrphy_cpd_lock        (                  ),
        .ddr_init_done          ( ddr_init_done    ),

        // 写地址通道
        .axi_awaddr             ( m_awaddr         ),
        .axi_awuser_ap          ( m_awap      ),
        .axi_awuser_id          ( m_awid             ),
        .axi_awlen              ( m_awlen          ),
        .axi_awready            ( m_awready        ),
        .axi_awvalid            ( m_awvalid        ),

        // 写数据通道 (pull 型: 无 wvalid/wlast 输入)
        .axi_wdata              ( m_wdata          ),
        .axi_wstrb              ( m_wstrb          ),
        .axi_wready             ( m_wready         ),
        .axi_wusero_id          ( m_wid            ),
        .axi_wusero_last        ( m_wlast          ),

        // 读地址通道
        .axi_araddr             ( m_araddr         ),
        .axi_aruser_ap          ( m_arap      ),
        .axi_aruser_id          ( m_arid      ),
        .axi_arlen              ( m_arlen          ),
        .axi_arready            ( m_arready        ),
        .axi_arvalid            ( m_arvalid        ),

        // 读数据通道 (push 型: 无 rready)
        .axi_rdata              ( m_rdata          ),
        .axi_rid                ( m_rid            ),
        .axi_rlast              ( m_rlast          ),
        .axi_rvalid             ( m_rvalid         ),

        // APB 调试通道 (未用)
        .apb_clk                ( 1'b0             ),
        .apb_rst_n              ( 1'b0             ),
        .apb_sel                ( 1'b0             ),
        .apb_enable             ( 1'b0             ),
        .apb_addr               ( 8'd0             ),
        .apb_write              ( 1'b0             ),
        .apb_ready              (                  ),
        .apb_wdata              ( 16'd0            ),
        .apb_rdata              (                  ),

        // DDR3 物理接口
        .mem_rst_n              ( mem_rst_n        ),
        .mem_ck                 ( mem_ck           ),
        .mem_ck_n               ( mem_ck_n         ),
        .mem_cke                ( mem_cke          ),
        .mem_ras_n              ( mem_ras_n        ),
        .mem_cas_n              ( mem_cas_n        ),
        .mem_we_n               ( mem_we_n         ),
        .mem_odt                ( mem_odt          ),
        .mem_a                  ( mem_a            ),
        .mem_ba                 ( mem_ba           ),
        .mem_dqs                ( mem_dqs          ),
        .mem_dqs_n              ( mem_dqs_n        ),
        .mem_dq                 ( mem_dq           ),
        .mem_dm                 ( mem_dm           ),

        // 调试/校准 (默认关闭)
        .dbg_gate_start         ( 1'b0             ),
        .dbg_cpd_start          ( 1'b0             ),
        .dbg_ddrphy_rst_n       ( 1'b1             ),
        .dbg_gpll_scan_rst      ( 1'b0             ),
        .samp_position_dyn_adj  ( 1'b0             ),
        .init_samp_position_even( 16'd0            ),
        .init_samp_position_odd ( 16'd0            ),
        .wrcal_position_dyn_adj ( 1'b0             ),
        .init_wrcal_position    ( 16'd0            ),
        .force_read_clk_ctrl    ( 1'b0             ),
        .init_slip_step         ( 8'd0             ),
        .init_read_clk_ctrl     ( 6'd0             ),
        .debug_calib_ctrl       (                  ),
        .dbg_slice_status       (                  ),
        .dbg_slice_state        (                  ),
        .debug_data             (                  ),
        .dbg_dll_upd_state      (                  ),
        .debug_gpll_dps_phase   (                  ),
        .dbg_rst_dps_state      (                  ),
        .dbg_tran_err_rst_cnt   (                  ),
        .dbg_ddrphy_init_fail   ( ddr_init_fail    ),
        .debug_cpd_offset_adj   ( 1'b0             ),
        .debug_cpd_offset_dir   ( 1'b0             ),
        .debug_cpd_offset       ( 10'd0            ),
        .debug_dps_cnt_dir0     (                  ),
        .debug_dps_cnt_dir1     (                  ),
        .ck_dly_en              ( 1'b0             ),
        .init_ck_dly_step       ( 8'd0             ),
        .ck_dly_set_bin         (                  ),
        .align_error            (                  ),
        .debug_rst_state        (                  ),
        .debug_cpd_state        (                  )
    );

endmodule
