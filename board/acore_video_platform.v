module acore_video_platform #(
    parameter integer STANDALONE_CAPTURE=0,
    parameter integer RESET_HOLD_CYCLES=250000
)(
    input wire monitor_clk,
    input wire tensor_we,
    input wire [8:0] tensor_addr_wr,tensor_addr_rd,
    input wire [31:0] tensor_wdata,
    output wire [31:0] tensor_rdata,
    output wire cpu_ddr_clk,cpu_ddr_ready,system_rst_n,shared_fault,
    output wire [4:0] frame_available,
    output wire [159:0] frame_ids,
    output wire [2:0] frame_wr_slot,
    output wire frame_wr_active,
    input wire [4:0] frame_hold_mask,
    output wire [31:0] measured_shape,measured_period,
    input wire [27:0] cpu_awaddr,cpu_araddr,
    input wire cpu_awvalid,cpu_arvalid,cpu_awap,cpu_arap,
    input wire [3:0] cpu_awlen,cpu_arlen,cpu_awid,cpu_arid,
    output wire cpu_awready,cpu_arready,cpu_wready,cpu_wlast,cpu_rvalid,cpu_rlast,
    output wire [3:0] cpu_wid,cpu_rid,
    input wire [127:0] cpu_wdata,
    input wire [15:0] cpu_wstrb,
    output wire [127:0] cpu_rdata,

	input					button_rst_n,	// 按键复位

	// PCIE 接口
	input					ref_clk_p,		// 输入参考时钟 正端
	input					ref_clk_n,		// 输入参考时钟 负端
	input					perst_n,		// PCIe硬件复位
	input		[1:0]		rxn,			// PCIe接收数据 负端
	input		[1:0]		rxp,			// PCIe接收数据 正端
	output wire	[1:0]		txn,			// PCIe发送数据 负端
	output wire	[1:0]		txp,			// PCIe发送数据 正端

	// LED 信号
	output reg				ref_led,    	// 参考时钟指示灯
	output reg				pclk_led	,	// 用户时钟指示灯

    // HDMI input (MS7210)
    input                   sys_clk,
    input                   pixclk_in,
    input                   vs_in,
    input                   hs_in,
    input                   de_in,
    input       [7:0]       r_in,
    input       [7:0]       g_in,
    input       [7:0]       b_in,
    output                  hd_scl,
    inout                   hd_sda,
    output                  rx_rst_n,
    output                  rstn_out,

    // ======================== DDR3 物理接口 (frame_ring_ddr3) ========================
    output                  mem_rst_n,
    output                  mem_ck,
    output                  mem_ck_n,
    output                  mem_cke,
    output                  mem_cs_n,       // IP 内禁用片选, 顶层恒 0 拉低芯片 CS#
    output                  mem_ras_n,
    output                  mem_cas_n,
    output                  mem_we_n,
    output                  mem_odt,
    output      [14:0]      mem_a,
    output      [2:0]       mem_ba,
    inout       [1:0]       mem_dqs,
    inout       [1:0]       mem_dqs_n,
    inout       [15:0]      mem_dq,
    output      [1:0]       mem_dm
);
wire sync_perst_n;

localparam DEVICE_TYPE = 3'b000;			// 设备类型配置
localparam AXIS_SLAVE_NUM = 3;				// AXI4-Stream从设备数量

// 测试单元模式信号
wire			pcie_cfg_ctrl_en;			// PCIe配置控制使能
wire			axis_master_tready_cfg;		// 配置模块主机端就绪信号

wire			cfg_axis_slave0_tvalid;		// 配置流从设备0数据有效信号
wire	[127:0]	cfg_axis_slave0_tdata;		// 配置流从设备0数据
wire			cfg_axis_slave0_tlast;		// 配置流从设备0帧结束信号
wire			cfg_axis_slave0_tuser;		// 配置流从设备0用户自定义信号

// 多路选择器相关信号
wire			axis_master_tready_mem;		// 内存主机端就绪信号
wire			axis_master_tvalid_mem;		// 内存主机端数据有效信号
wire	[127:0]	axis_master_tdata_mem;		// 内存主机端数据
wire	[3:0]	axis_master_tkeep_mem;		// 内存主机端数据有效字节

wire			axis_master_tlast_mem;		// 内存主机端帧结束信号
wire	[7:0]	axis_master_tuser_mem;		// 内存主机端用户自定义信号

wire			cross_4kb_boundary;			// 跨4KB边界标志

wire			dma_axis_slave0_tvalid;		// DMA流从设备0数据有效信号
wire	[127:0]	dma_axis_slave0_tdata;		// DMA流从设备0数据
wire			dma_axis_slave0_tlast;		// DMA流从设备0帧结束信号
wire			dma_axis_slave0_tuser;		// DMA流从设备0用户自定义信号

// 复位消抖与同步信号
wire			sync_button_rst_n; 			// 同步后的按键复位
wire			ref_core_rst_n;				// 参考时钟域内核复位
wire			s_pclk_rstn;				// 用户时钟域同步复位

// 内部时钟信号
wire			pclk_div2/*synthesis PAP_MARK_DEBUG="1"*/;  	// 用户二分频时钟 5GT/s时125MHz 2.5GT/s时62.5MHz
wire			pclk/*synthesis PAP_MARK_DEBUG="1"*/;			// 用户时钟 5GT/s时125MHz 2.5GT/s时62.5MHz
wire			ref_clk; 						// 参考时钟
wire			core_rst_n;					// 内核复位信号

// AXI4-Stream主机接口
wire			axis_master_tvalid;			// 主机端数据有效
wire			axis_master_tready;			// 主机端就绪
wire	[127:0]	axis_master_tdata;			// 主机端数据
wire	[3:0]	axis_master_tkeep;			// 主机端数据有效字节
wire			axis_master_tlast;			// 主机端帧结束
wire	[7:0]	axis_master_tuser;			// 主机端用户自定义信号

// AXI4-Stream从设备0接口
wire			axis_slave0_tready;			// 从设备0就绪
wire			axis_slave0_tvalid;			// 从设备0数据有效
wire	[127:0]	axis_slave0_tdata;			// 从设备0数据
wire			axis_slave0_tlast;			// 从设备0帧结束
wire			axis_slave0_tuser;			// 从设备0用户自定义信号
// AXI4-Stream从设备1接口
wire			axis_slave1_tready;			// 从设备1就绪
wire			axis_slave1_tvalid;			// 从设备1数据有效
wire	[127:0]	axis_slave1_tdata;			// 从设备1数据
wire			axis_slave1_tlast;			// 从设备1帧结束
wire			axis_slave1_tuser;			// 从设备1用户自定义信号
// AXI4-Stream从设备2接口
wire			axis_slave2_tready;			// 从设备2就绪
wire			axis_slave2_tvalid;			// 从设备2数据有效
wire	[127:0]	axis_slave2_tdata;			// 从设备2数据
wire			axis_slave2_tlast;			// 从设备2帧结束
wire			axis_slave2_tuser;			// 从设备2用户自定义信号

// PCIe配置信号
wire	[7:0]	cfg_pbus_num;				// 总线编号
wire	[4:0]	cfg_pbus_dev_num; 			// 设备编号
wire	[2:0]	cfg_max_rd_req_size;		// 最大读请求大小
wire	[2:0]	cfg_max_payload_size;		// 最大有效载荷大小
wire			cfg_rcb;					// 读完成边界

// PCIe流量控制信用量信号
wire			cfg_ido_req_en;				// ID有序请求使能
wire			cfg_ido_cpl_en;				// ID有序完成使能
wire	[7:0]	xadm_ph_cdts;				// 发布头信用量
wire	[11:0]	xadm_pd_cdts;				// 发布数据信用量
wire	[7:0]	xadm_nph_cdts;				// 非发布头信用量
wire	[11:0]	xadm_npd_cdts;				// 非发布数据信用量
wire	[7:0]	xadm_cplh_cdts;				// 完成头信用量
wire	[11:0]	xadm_cpld_cdts;				// 完成数据信用量

wire	[4:0]	smlh_ltssm_state/*synthesis PAP_MARK_DEBUG="1"*/;//链路状态机状态

// LED闪烁计数信号
reg		[22:0]	ref_led_cnt;				// 参考时钟LED计数器
reg		[26:0]	pclk_led_cnt;				// 用户时钟LED计数器
wire			smlh_link_up; 				// 物理层链路建立标志
wire			rdlh_link_up/*synthesis PAP_MARK_DEBUG="1"*/; 	// 数据链路层建立标志

// UART转APB 32位接口信号
wire			uart_p_sel;					// UART转APB片选
wire	[3:0]	uart_p_strb;				// UART转APB字节选通
wire	[15:0]	uart_p_addr;				// UART转APB地址
wire	[31:0]	uart_p_wdata;				// UART转APB写数据
wire			uart_p_ce;					// UART转APB时钟使能
wire			uart_p_we;					// UART转APB写使能
wire			uart_p_rdy;					// UART转APB就绪
wire	[31:0]	uart_p_rdata;				// UART转APB读数据

// APB总线信号
wire	[3:0]	p_strb; 					// APB字节选通
wire	[15:0]	p_addr; 					// APB地址
wire	[31:0]	p_wdata; 					// APB写数据
wire			p_ce; 						// APB时钟使能
wire			p_we; 						// APB写使能

// APB多路选择器信号
// 0~5: 高速串行收发器 6: 保留 7: PCIe
// 8: 配置模块
// 9: DMA模块
wire			p_sel_pcie;					// APB选择PCIe
wire			p_sel_cfg;					// APB选择配置模块
wire			p_sel_dma;					// APB选择DMA模块

wire	[31:0]	p_rdata_pcie;				// PCIe读数据
wire	[31:0]	p_rdata_cfg;				// 配置模块读数据
wire	[31:0]	p_rdata_dma;				// DMA模块读数据

wire			p_rdy_pcie;					// PCIe就绪
wire			p_rdy_cfg;					// 配置模块就绪
wire			p_rdy_dma;					// DMA模块就绪

// 原始代码: 测试用绿色常量数据
// reg [127:0] test_green_data = 128'h00FF0000_00FF0000_00FF0000_00FF0000;
// wire test_tx_valid    = 1'b1;
// wire i_user_data_last = 1'b0;

//++ [改动] 调试模式开关 + HDMI→FIFO→DMA 数据通路
// DEBUG_MODE: 0 = 测试数据直连DMA（绕过FIFO，验证DMA通路）
//             1 = FIFO通路 + 自增计数器（验证FIFO+Pipeline+TLP门控）
//             2 = FIFO通路 + 真实HDMI像素（正式视频采集模式）
localparam DEBUG_MODE = 2;

//++ [改动H] 纯色测试常量（RGB565格式）
// 红色: 0xF800  绿色: 0x07E0  蓝色: 0x001F  白色: 0xFFFF  黑色: 0x0000
// 修改此值切换测试颜色，MODE 0和MODE 1均使用此值
localparam [15:0] TEST_SOLID_COLOR = 16'hF800;  // 纯红（endian_convert处理字节翻转）
//-- [改动H] 结束

// --- 测试数据（仅 DEBUG_MODE=0 时有效）---
// 原始代码: wire [127:0] test_green_data = 128'h00FF0000_...;
// 原始代码(改动前): 自增计数器 test_base_cnt + 16'd0~7
//++ [改动H] 替换自增计数器为纯色常量，128位 = 8个相同的16位RGB565纯色
wire [127:0] test_inc_data = {8{TEST_SOLID_COLOR}};
//-- [改动H] 结束

// --- HDMI 像素数据 ---
// 当前使用 RGB565 (16-bit)，由 hdmi_in_demo.pixel_16bit_out 输出
// hdmi_pixel = {r_in[7:3], g_in[7:2], b_in[7:3]}
// host 端: SDL2 使用 SDL_PIXELFORMAT_RGB565, transfer_dw = W*H/2
//
// [TODO: 升级为 ARGB8888 的步骤]
// 1. PDS 重新生成 a_fifi IP: WR_DATA_WIDTH=32, RD_DATA_WIDTH=128, WR_DEPTH=4096
// 2. 恢复像素格式化: wire [31:0] hdmi_argb = {b_in, g_in, r_in, 8'hFF};
// 3. FIFO .wr_data 改接 hdmi_argb（32-bit）
// 4. Host: transfer_dw=W*H, SDL2改ARGB8888, pitch=W*4, PPM按ARGB解析
// 5. 字节序: FPGA {B,G,R,FF} → endian_convert → host 0xFFRRGGBB

// --- frame_ring_ddr3 读侧信号（读侧 128bit @ pclk_div2）---
wire         fifo_rd_empty;
wire         fifo_almost_empty;
wire [127:0] ring_raw_rd_data;   // DDR3 读回的原始 RGB565×8 (未处理)
wire [127:0] fifo_rd_data;       // 经 ddr3_color_mask 处理后的掩膜×8 (喂给 shadow/pipe→DMA)
wire         fifo_rd_en;

wire dma_mwr_tx_busy;

wire        hdmi_pixclk;

// ---- lpdetection 输出信号 ----
wire        hdmi_vs;        // 车牌检测流水线输出 vsync
wire        hdmi_de;        // 车牌检测流水线输出 de
wire [15:0] hdmi_pixel;     // 车牌检测流水线输出 edge_binary 灰度

// ---- CCA 调试信号 (hdmi_pixclk 域) ----
wire        cca_dbg_overflow_pix;  // 标签池溢出
wire        cca_dbg_valid_pix;     // 帧完成翻转 (每帧闪一次)

// 同步器: hdmi_pixclk → pclk
reg  [1:0]  cca_dbg_sync_pclk;
reg  [1:0]  cca_dbg_ovf_sync_pclk;
reg  [1:0]  cca_dbg_ovf_sync_ref;


// [DDR3环形帧缓冲] frame_ring_ddr3 内部按 marker 自对齐帧, 读侧自治,
//   不再需要 DMA 启动触发的 FIFO 复位 / 帧同步状态机 / frame_active 门控。
//   pipeline(shadow/pipe) 仅在系统复位时清零, 运行期不复位。
wire frame_rst_pcie = 1'b0;

// DDR3 输出核心时钟(~131MHz, 由 sys_clk 倍频得到; 导出但顶层未用)
wire ddr_core_clk;

//++ [数据源开关] 0 = 原始HDMI RGB565 直接入DDR3 (颜色识别改到读侧, 本版默认)
//                1 = 车牌检测流水线(lpdetection, 边缘检测) 结果入DDR3 (旧版, 保留可回退)
//   新架构: 所有颜色识别下沉到 DDR3 之后 (ddr3_color_mask), 故写侧存原始彩色帧。
localparam USE_LPDETECTION = 0;

wire capture_vs,capture_de;
wire [23:0] capture_rgb;
wire [15:0] raw_hdmi_pixel = {capture_rgb[23:19], capture_rgb[15:10], capture_rgb[7:3]};
wire        ring_vs      = USE_LPDETECTION ? hdmi_vs    : vs_in;
wire        ring_de      = USE_LPDETECTION ? hdmi_de    : de_in;
wire [15:0] ring_wr_data = USE_LPDETECTION ? hdmi_pixel : raw_hdmi_pixel;

// 原始代码: FIFO写侧自增计数器 fifo_test_cnt + 16'd1
//++ [改动H] FIFO写侧纯色常量（替代自增计数器，用于MODE 1色彩诊断）
// MODE 1时FIFO每拍写入同一纯色值，读侧128位应为8个相同像素
wire [15:0] fifo_test_data = TEST_SOLID_COLOR;
//-- [改动H] 结束

// --- DMA 用户数据：根据 DEBUG_MODE 选择数据源 ---
wire         user_data_rdy;
wire [127:0] dma_user_data;
wire         dma_user_data_vld;

//++ [改动] 2026-05-04 改动A：2级流水线(shadow+pipe)消除HEADER_TX→DATA_TX tvld间断
//   原1级pipeline在HEADER_TX期间不读FIFO，导致DATA_TX首拍后pipe_valid
//   跌落1周期，产生tvld间隙。PCIe IP不容忍TLP内数据中断，累积后卡死。
//   修复：shadow寄存器在IDLE/HEADER_TX期间预取下一拍数据，DATA_TX首拍
//   从shadow补充pipe，之后FIFO数据直通pipe，实现零间隙连续传输。
reg          fifo_rd_en_d1;
reg  [127:0] shadow_data;
reg          shadow_valid;
reg  [127:0] pipe_data;
reg          pipe_valid;

always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)         fifo_rd_en_d1 <= 1'b0;
    else if (frame_rst_pcie) fifo_rd_en_d1 <= 1'b0;
    else                     fifo_rd_en_d1 <= fifo_rd_en;
end

wire pipe_can_accept = !pipe_valid || (user_data_rdy && pipe_valid);

wire data_to_pipe    = fifo_rd_en_d1 &&  pipe_can_accept;
wire data_to_shadow  = fifo_rd_en_d1 && !pipe_can_accept && !shadow_valid;

wire shadow_to_pipe  = shadow_valid && pipe_can_accept && !data_to_pipe;

wire pipe_load_any   = data_to_pipe || shadow_to_pipe;
wire pipe_drain      = user_data_rdy && pipe_valid;

always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)           shadow_data <= 128'd0;
    else if (frame_rst_pcie)   shadow_data <= 128'd0;
    else if (data_to_shadow)   shadow_data <= ring_raw_rd_data;//fifo_rd_data
end

always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)           shadow_valid <= 1'b0;
    else if (frame_rst_pcie)   shadow_valid <= 1'b0;
    else begin
        case ({data_to_shadow, shadow_to_pipe})
            2'b10:   shadow_valid <= 1'b1;
            2'b01:   shadow_valid <= 1'b0;
            default: shadow_valid <= shadow_valid;
        endcase
    end
end

always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)           pipe_data <= 128'd0;
    else if (frame_rst_pcie)   pipe_data <= 128'd0;
    else if (data_to_pipe)     pipe_data <= ring_raw_rd_data;//fifo_rd_data
    else if (shadow_to_pipe)   pipe_data <= shadow_data;
end

always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)           pipe_valid <= 1'b0;
    else if (frame_rst_pcie)   pipe_valid <= 1'b0;
    else begin
        case ({pipe_load_any, pipe_drain})
            2'b10:   pipe_valid <= 1'b1;
            2'b01:   pipe_valid <= 1'b0;
            default: pipe_valid <= pipe_valid;
        endcase
    end
end

// 原始代码: assign fifo_rd_en = !fifo_rd_empty && (
//     (!pipe_valid || user_data_rdy) ||
//     (!shadow_valid)
// );
//++ [改动G] 防止TLP边界多读一拍丢数据：shadow读取加d1保护
//   FIFO设置了OUTPUT_REG=1(DOB_REG=1)，读数据经输出寄存器。
//   当fifo_rd_en_d1=1时，上一拍读出的数据即将到达，此时shadow可能被填满，
//   不应再发新读。加(!fifo_rd_en_d1)保护后，shadow填充变为隔拍读取，
//   避免数据到达时无处存放而丢失。
//   DATA_TX期间user_data_rdy=1，走第一个条件(!pipe_valid||user_data_rdy)，
//   连续每拍读取不受此保护影响，带宽不降低。
assign fifo_rd_en = !fifo_rd_empty && (
    (!pipe_valid || user_data_rdy) ||
    (!shadow_valid && !fifo_rd_en_d1)
);
//-- [改动G] 结束
assign dma_user_data     = (DEBUG_MODE == 0) ? test_inc_data : pipe_data;
assign dma_user_data_vld = (DEBUG_MODE == 0) ? 1'b1          : pipe_valid;


// 流量控制相关信号默认赋值
assign cfg_ido_req_en	=	1'b0;		// 关闭ID有序请求
assign cfg_ido_cpl_en	=	1'b0;		// 关闭ID有序完成
assign xadm_ph_cdts		=	8'b0;		// 发布头信用量清零
assign xadm_pd_cdts		=	12'b0;		// 发布数据信用量清零
assign xadm_nph_cdts	=	8'b0;		// 非发布头信用量清零
assign xadm_npd_cdts	=	12'b0;		// 非发布数据信用量清零
assign xadm_cplh_cdts	=	8'b0;		// 完成头信用量清零
assign xadm_cpld_cdts	=	12'b0;		// 完成数据信用量清零





// ===================== HDMI Input (MS7210) =====================
// SPI image build: all pixel processing runs from committed DDR data.
assign hd_scl=1'b1;
assign hd_sda=1'bz;
assign rx_rst_n=1'b0;
assign rstn_out=1'b1;
assign hdmi_pixclk=monitor_clk;



// ===================== 车牌检测流水线 =====================
// RGB888 → YCbCr → Sobel → edge_binary 灰度 → hdmi_pixel
assign cca_dbg_overflow_pix=1'b0;
assign cca_dbg_valid_pix=1'b0;






// 原始代码: a_fifi u_hdmi_fifo (...异步FIFO...);
//++ [DDR3环形帧缓冲] 用 frame_ring_ddr3 替换异步 FIFO。
//   实例名保持 u_hdmi_fifo、内部 DDR3 IP 名为 u_ddr3, 以匹配 fdc 中
//   u_hdmi_fifo.u_ddr3.* 的时钟/PHY 固定位置约束。
//   写侧(hdmi_pixclk): 喂 vs/de/16bit像素(由 USE_LPDETECTION 选择数据源)。
//   读侧(pclk_div2)  : 128bit, 呈现与 a_fifi 相同的 rd_data/rd_empty/almost_empty 接口。
//   帧对齐由内部 marker 驱动, 读侧自治, 无需外部 wr_rst/rd_rst/frame_active。
wire application_rst_n;
generate if(STANDALONE_CAPTURE)begin: g_local_application_reset
    // CPU, DDR and preprocessing must run with no PCIe reference clock/PERST#.
    // The PCIe IP and DMA retain their original reset and clock connections.
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_local_reset(
        .clk(monitor_clk),.key0_n(button_rst_n),.rst_n(application_rst_n));
end else begin: g_pcie_application_reset
    assign application_rst_n=core_rst_n;
end endgenerate
wire [31:0] source_next_id,raw_begin_id,raw_end_id;
wire source_ready,raw_begin,raw_accepted,raw_end,raw_end_ok,tensor_fault;
wire [2:0] raw_begin_slot,raw_end_slot;
wire [4:0] tensor_hold;
wire [27:0] tensor_awaddr;
wire tensor_awvalid,tensor_awap,tensor_awready,tensor_wready,tensor_wlast;
wire [3:0] tensor_awlen,tensor_awid,tensor_wid;
wire [127:0] tensor_write_data;
wire [15:0] tensor_wstrb;
wire [31:0] capture_rdata,present_rdata;
wire [4:0] present_frames,present_hold,present_box_count;
wire [1023:0] present_boxes;
wire presentation_read_busy,presentation_read_done;
assign tensor_rdata=tensor_addr_rd[8]?present_rdata:capture_rdata;
video_present_control #(.WIDTH(384),.HEIGHT(216)) u_present(
    .clk(monitor_clk),.core_clk(ddr_core_clk),.pcie_clk(pclk_div2),.rst_n(application_rst_n),
    .pcie_rst_n(core_rst_n),.pcie_link_up(smlh_link_up&&rdlh_link_up),.ddr_ready(cpu_ddr_ready),
    .dev_we(tensor_we&&tensor_addr_wr[8]),.addr_wr(tensor_addr_wr[7:0]),.addr_rd(tensor_addr_rd[7:0]),
    .wdata(tensor_wdata),.rdata(present_rdata),.frame_available(frame_available),.frame_held(frame_hold_mask|tensor_hold),
    .frame_ids(frame_ids),.write_slot(frame_wr_slot),.write_active(frame_wr_active),
    .reader_busy(presentation_read_busy),.reader_done(presentation_read_done),
    .pixel_valid(dma_user_data_vld),.pixel_ready(user_data_rdy),.dma_busy(dma_mwr_tx_busy),
    .stream_empty(fifo_rd_empty&&!pipe_valid&&!shadow_valid&&!fifo_rd_en_d1),
    .reader_frames(present_frames),.protect_mask(present_hold),.active_count(present_box_count),.active_boxes(present_boxes));
assign cpu_ddr_clk=ddr_core_clk;
assign system_rst_n=application_rst_n;
assign measured_shape=(32'd216<<16)|32'd384;
assign measured_period=0;
assign capture_vs=0;assign capture_de=0;assign capture_rgb=0;
wire image_active,image_held,image_available,image_fault;
wire [31:0] image_id;
wire [27:0] image_awaddr,image_araddr;
wire image_awvalid,image_arvalid,image_awap,image_arap;
wire [3:0] image_awlen,image_arlen,image_awid,image_arid,image_wid,image_rid;
wire image_awready,image_arready,image_wready,image_wlast,image_rvalid,image_rlast;
wire [127:0] image_wdata,image_rdata;
wire [15:0] image_wstrb;
assign tensor_awaddr=0;assign tensor_awvalid=0;assign tensor_awap=0;
assign tensor_awlen=0;assign tensor_awid=0;assign tensor_write_data=0;assign tensor_wstrb=0;
assign tensor_hold={4'b0,image_held};assign tensor_fault=image_fault;
spi_image_capture u_preprocess (
    .clk(monitor_clk),.core_clk(ddr_core_clk),.rst_n(application_rst_n),
    .ddr_ready(cpu_ddr_ready),.shared_fault(shared_fault),.external_hold(frame_hold_mask|present_hold),
    .dev_we(tensor_we&&!tensor_addr_wr[8]),.addr_wr(tensor_addr_wr[7:0]),.addr_rd(tensor_addr_rd[7:0]),
    .wdata(tensor_wdata),.rdata(capture_rdata),
    .active(image_active),.held(image_held),.available(image_available),.frame_id(image_id),.fault(image_fault),
    .axi_awaddr(image_awaddr),.axi_araddr(image_araddr),.axi_awvalid(image_awvalid),.axi_arvalid(image_arvalid),
    .axi_awap(image_awap),.axi_arap(image_arap),.axi_awlen(image_awlen),.axi_arlen(image_arlen),
    .axi_awid(image_awid),.axi_arid(image_arid),.axi_awready(image_awready),.axi_arready(image_arready),
    .axi_wdata(image_wdata),.axi_wstrb(image_wstrb),.axi_wready(image_wready),.axi_wlast(image_wlast),.axi_wid(image_wid),
    .axi_rdata(image_rdata),.axi_rvalid(image_rvalid),.axi_rlast(image_rlast),.axi_rid(image_rid));
frame_ring_ddr3 #(.SPI_IMAGE(1),.H_ACTIVE(384),.V_ACTIVE(216),.ENABLE_PCIE_READER(1),.CONTROLLED_READER(1)) u_hdmi_fifo (
  .image_active(image_active),.image_held(image_held),.image_available(image_available),.image_fault(image_fault),.image_id(image_id),
  .image_awaddr(image_awaddr),.image_araddr(image_araddr),.image_awvalid(image_awvalid),.image_arvalid(image_arvalid),
  .image_awap(image_awap),.image_arap(image_arap),.image_awlen(image_awlen),.image_arlen(image_arlen),.image_arid(image_arid),
  .image_wdata(image_wdata),.image_wstrb(image_wstrb),.image_awready(image_awready),.image_arready(image_arready),
  .image_wready(image_wready),.image_wlast(image_wlast),.image_wid(image_wid),
  .image_rvalid(image_rvalid),.image_rlast(image_rlast),.image_rid(image_rid),.image_rdata(image_rdata),
  .present_frames(present_frames),.present_hold(present_hold),.present_box_count(present_box_count),.present_boxes(present_boxes),
  .tensor_awaddr(tensor_awaddr),.tensor_awvalid(tensor_awvalid),.tensor_awap(tensor_awap),
  .tensor_awlen(tensor_awlen),.tensor_awid(tensor_awid),.tensor_awready(tensor_awready),
  .tensor_wdata(tensor_write_data),.tensor_wstrb(tensor_wstrb),.tensor_wready(tensor_wready),
  .tensor_wlast(tensor_wlast),.tensor_wid(tensor_wid),.tensor_hold(tensor_hold),.tensor_fault(tensor_fault),
  .source_next_id(source_next_id),.source_ready(source_ready),.raw_begin(raw_begin),.raw_accepted(raw_accepted),
  .raw_begin_id(raw_begin_id),.raw_begin_slot(raw_begin_slot),.raw_end(raw_end),
  .raw_end_ok(raw_end_ok),.raw_end_id(raw_end_id),.raw_end_slot(raw_end_slot),
  .cpu_awaddr(cpu_awaddr),.cpu_araddr(cpu_araddr),.cpu_awvalid(cpu_awvalid),.cpu_arvalid(cpu_arvalid),
  .cpu_awap(cpu_awap),.cpu_arap(cpu_arap),.cpu_awlen(cpu_awlen),.cpu_arlen(cpu_arlen),
  .cpu_awid(cpu_awid),.cpu_arid(cpu_arid),.cpu_awready(cpu_awready),.cpu_arready(cpu_arready),
  .cpu_wready(cpu_wready),.cpu_wlast(cpu_wlast),.cpu_wid(cpu_wid),.cpu_rvalid(cpu_rvalid),
  .cpu_rlast(cpu_rlast),.cpu_rid(cpu_rid),.cpu_wdata(cpu_wdata),.cpu_wstrb(cpu_wstrb),.cpu_rdata(cpu_rdata),
  // Accept the normalized stream like the proven reference. The monitor is
  // diagnostic; raw completion and tensor integrity qualify the retained pair.
  .hold_mask(frame_hold_mask),.stream_ok(1'b1),.available(frame_available),.frame_ids(frame_ids),
  .write_slot(frame_wr_slot),.write_active(frame_wr_active),.shared_fault(shared_fault),
  // 时钟与复位
  .sys_clk        (sys_clk),          // 25MHz -> DDR3 参考时钟
  .sys_rst_n      (application_rst_n), // local or original PCIe application reset
  .clr            (1'b0),             // 保留未用
  .core_clk       (ddr_core_clk),     // DDR3 输出核心时钟(导出, 顶层未用)
  .ddr_init_done  (cpu_ddr_ready),
  .ddr_pll_lock   (),
  .ddr_init_fail  (),

  // 诊断(未用)
  .dbg_vs_seen      (),
  .dbg_wr_done_seen (),
  .dbg_read_started (),
  .dbg_frame_done   (),
  .dbg_rd_fifo_ovf  (),
  .dbg_sof_bad      (),
  .dbg_wr_sof_bad   (),

  // 写侧 (hdmi_pixclk)
  .wr_clk         (hdmi_pixclk),
  .wr_data        (raw_hdmi_pixel),     // 16bit 像素 (USE_LPDETECTION 选择源)
  .wr_en          (1'b0),             // detector 以 de 自门控, 未用
  .vs             (capture_vs),
  .de             (capture_de),
  .wr_almost_full (),                 // 未用(写侧自流控)

  // 读侧 (pclk_div2)
  .rd_clk         (pclk_div2),        // PCIe 用户时钟 (62.5MHz)
  .dma_start      (1'b0),             // 读侧自治, 未用
  .rd_data        (ring_raw_rd_data), // 128-bit = 8 个原始 RGB565 像素 (送入 color_mask)
  .rd_en          (fifo_rd_en),       // 读使能 = pipeline 有空间
  .rd_empty       (fifo_rd_empty),    // 读空标志
  .rd_almost_empty(fifo_almost_empty),// FIFO 数据不足标志(TLP 发起门控)
  .read_busy      (presentation_read_busy),
  .read_done      (presentation_read_done),

  // 状态(未用)
  .frame_valid    (),
  .wr_slot        (),

  // DDR3 物理接口
  .mem_rst_n      (mem_rst_n),
  .mem_ck         (mem_ck),
  .mem_ck_n       (mem_ck_n),
  .mem_cke        (mem_cke),
  .mem_ras_n      (mem_ras_n),
  .mem_cas_n      (mem_cas_n),
  .mem_we_n       (mem_we_n),
  .mem_odt        (mem_odt),
  .mem_a          (mem_a),
  .mem_ba         (mem_ba),
  .mem_dqs        (mem_dqs),
  .mem_dqs_n      (mem_dqs_n),
  .mem_dq         (mem_dq),
  .mem_dm         (mem_dm)
);

// mem_cs_n: DDR3 IP 内禁用片选, 顶层恒 0 永久拉低芯片 CS#
assign mem_cs_n = 1'b0;


// 复位消抖模块
hsst_rst_cross_sync_v1_0 #(
	.RST_CNTR_VALUE		(16'hC000)
) u_refclk_buttonrstn_debounce (
	.clk				(ref_clk),			// 工作时钟
	.rstn_in			(button_rst_n), 	// 输入复位
	.rstn_out			(sync_button_rst_n) // 输出同步复位
);

hsst_rst_cross_sync_v1_0 #(
	.RST_CNTR_VALUE		(16'hC000)
) u_refclk_perstn_debounce (
	.clk				(ref_clk), 			// 工作时钟
	.rstn_in			(perst_n),			// 输入硬件复位
	.rstn_out			(sync_perst_n)		// 输出同步硬件复位
);

hsst_rst_sync_v1_0  u_ref_core_rstn_sync (
	.clk				(ref_clk), 			// 工作时钟
	.rst_n				(core_rst_n),		// 内核复位
	.sig_async			(1'b1),
	.sig_synced			(ref_core_rst_n)	// 同步后的复位
);

hsst_rst_sync_v1_0  u_pclk_core_rstn_sync (
	.clk				(pclk),				// 工作时钟
	.rst_n				(core_rst_n),		// 内核复位
	.sig_async			(1'b1),
	.sig_synced			(s_pclk_rstn)		// 同步后的复位
);

	// CCA 调试同步器: hdmi_pixclk -> pclk
	always @(posedge pclk or negedge s_pclk_rstn) begin
		if (!s_pclk_rstn) begin
			cca_dbg_sync_pclk     <= 2'b0;
			cca_dbg_ovf_sync_pclk <= 2'b0;
		end else begin
			cca_dbg_sync_pclk     <= {cca_dbg_sync_pclk[0],     cca_dbg_valid_pix};
			cca_dbg_ovf_sync_pclk <= {cca_dbg_ovf_sync_pclk[0], cca_dbg_overflow_pix};
		end
	end

	// CCA 调试同步器: hdmi_pixclk -> ref_clk
	always @(posedge ref_clk or negedge sync_perst_n) begin
		if (!sync_perst_n) begin
			cca_dbg_ovf_sync_ref <= 2'b0;
		end else begin
			cca_dbg_ovf_sync_ref <= {cca_dbg_ovf_sync_ref[0], cca_dbg_overflow_pix};
		end
	end

	// 参考时钟LED控制逻辑 (CCA溢出: 常亮=正常, 灭=溢出)
	always @(posedge ref_clk or negedge sync_perst_n) begin
		if (!sync_perst_n) begin
			ref_led <= 1'b1;
		end else if (smlh_link_up & rdlh_link_up) begin
			ref_led <= ~cca_dbg_ovf_sync_ref[1];
		end
	end

	// 用户时钟LED控制逻辑 (CCA帧完成: 每帧翻转闪动)
	always @(posedge pclk or negedge s_pclk_rstn) begin
		if (!s_pclk_rstn) begin
			pclk_led <= 1'b1;
		end else if (smlh_link_up & rdlh_link_up) begin
			pclk_led <= cca_dbg_sync_pclk[1];
		end
	end

// UART转APB顶层模块
// UART/APB debug is disabled; AB21 belongs to HDMI r_in[7].
assign uart_p_sel=0;assign uart_p_strb=0;assign uart_p_addr=0;assign uart_p_wdata=0;
assign uart_p_ce=0;assign uart_p_we=0;
assign p_strb=0;assign p_addr=0;assign p_wdata=0;assign p_ce=0;assign p_we=0;
assign p_sel_pcie=0;assign p_sel_dma=0;assign p_sel_cfg=0;
ips2l_pcie_dma #(
	.DEVICE_TYPE			(DEVICE_TYPE),
	.AXIS_SLAVE_NUM			(AXIS_SLAVE_NUM)
) u_ips2l_pcie_dma (
	.clk					(pclk_div2),				// 工作时钟
	.rst_n					(core_rst_n),				// 复位信号

	// 配置参数
	.i_cfg_pbus_num			(cfg_pbus_num),				// 总线编号
	.i_cfg_pbus_dev_num		(cfg_pbus_dev_num),			// 设备编号
	.i_cfg_max_rd_req_size	(cfg_max_rd_req_size),		// 最大读请求大小
	.i_cfg_max_payload_size	(cfg_max_payload_size),		// 最大有效载荷大小

	// AXI4-Stream主机接口
	.i_axis_master_tvld		(axis_master_tvalid_mem),	// 主机数据有效
	.o_axis_master_trdy		(axis_master_tready_mem),	// 主机就绪
	.i_axis_master_tdata	(axis_master_tdata_mem),	// 主机数据
	.i_axis_master_tkeep	(axis_master_tkeep_mem),	// 主机数据有效字节

	.i_axis_master_tlast	(axis_master_tlast_mem),	// 主机帧结束
	.i_axis_master_tuser	(axis_master_tuser_mem),	// 主机用户自定义信号

	// AXI4-Stream从设备0接口
	.i_axis_slave0_trdy		(axis_slave0_tready),		// 从设备0就绪这个信号虽然叫从设备1准备就绪 即使从设备是数据输出方 实际上是对面的接收数据方准备好接收数据 所以有用‘
	.o_axis_slave0_tvld		(dma_axis_slave0_tvalid),	// 从设备0数据有效
	.o_axis_slave0_tdata	(dma_axis_slave0_tdata),	// 从设备0数据
	.o_axis_slave0_tlast	(dma_axis_slave0_tlast),	// 从设备0帧结束
	.o_axis_slave0_tuser	(dma_axis_slave0_tuser),	// 从设备0用户自定义信号

	// AXI4-Stream从设备1接口
	.i_axis_slave1_trdy		(axis_slave1_tready),		// 从设备1就绪
	.o_axis_slave1_tvld		(axis_slave1_tvalid),		// 从设备1数据有效
	.o_axis_slave1_tdata	(axis_slave1_tdata),		// 从设备1数据
	.o_axis_slave1_tlast	(axis_slave1_tlast),		// 从设备1帧结束
	.o_axis_slave1_tuser	(axis_slave1_tuser),		// 从设备1用户自定义信号

	// AXI4-Stream从设备2接口
	.i_axis_slave2_trdy		(axis_slave2_tready),		// 从设备2就绪
	.o_axis_slave2_tvld		(axis_slave2_tvalid),		// 从设备2数据有效
	.o_axis_slave2_tdata	(axis_slave2_tdata),		// 从设备2数据
	.o_axis_slave2_tlast	(axis_slave2_tlast),		// 从设备2帧结束
	.o_axis_slave2_tuser	(axis_slave2_tuser),		// 从设备2用户自定义信号

	// PCIe配置输入 目前被挂起
	.i_cfg_ido_req_en		(cfg_ido_req_en),			// ID有序请求使能
	.i_cfg_ido_cpl_en		(cfg_ido_cpl_en),			// ID有序完成使能
	.i_xadm_ph_cdts			(xadm_ph_cdts),				// 发布头信用量
	.i_xadm_pd_cdts			(xadm_pd_cdts),				// 发布数据信用量
	.i_xadm_nph_cdts		(xadm_nph_cdts),			// 非发布头信用量
	.i_xadm_npd_cdts		(xadm_npd_cdts),			// 非发布数据信用量
	.i_xadm_cplh_cdts		(xadm_cplh_cdts),			// 完成头信用量
	.i_xadm_cpld_cdts		(xadm_cpld_cdts),			// 完成数据信用量

	// APB接口 调试接口不使用
	.i_apb_psel				(p_sel_dma),				// APB片选
	.i_apb_paddr			(p_addr[8:0]),				// APB地址
	.i_apb_pwdata			(p_wdata),					// APB写数据
	.i_apb_pstrb			(p_strb),					// APB字节选通
	.i_apb_pwrite			(p_we),						// APB写使能
	.i_apb_penable			(p_ce),						// APB使能
	.o_apb_prdy				(p_rdy_dma),				// APB就绪
	.o_apb_prdata			(p_rdata_dma),				// APB读数据
	.o_cross_4kb_boundary	(cross_4kb_boundary),		// 跨4KB边界标志


      // 原始代码: .i_user_data(test_green_data), .i_user_data_vld(test_tx_valid), .o_user_data_rdy(), .i_user_data_last(i_user_data_last)
      //++ [改动] 用户数据接口：通过 DEBUG_MODE 选择测试数据或 HDMI+FIFO
      .i_user_data                (dma_user_data             ),   // DEBUG_MODE=0: 测试数据, =1: FIFO 数据
      .i_user_data_vld            (dma_user_data_vld         ),   // DEBUG_MODE=0: 常高, =1: FIFO 非空
      .o_user_data_rdy            (user_data_rdy             ),   // DMA 就绪信号（驱动 FIFO rd_en）
      .i_user_data_last           (1'b0                      ),   // 未使用，DMA 内部自计数
      //-- [改动] 结束
      //++ [改动] 传入FIFO数据充足信号，用于TLP发起门控
      //   frame_ring 读侧自治, almost_empty 直接反映环形缓冲余量。
      .i_fifo_data_sufficient     (!fifo_almost_empty),
      //++ [改动] DMA TX忙信号，用于安全帧复位门控
      .o_dma_tx_busy              (dma_mwr_tx_busy           )
      //-- [改动] 结束





);

// 配置控制模块 在ep模式配置模块被跳过 dma直通pcie数据包
generate
	if (DEVICE_TYPE == 3'd4) begin:rc  // RC模式
	//PCIe配置TLP发送/接收 基地址 = 0x9000
		pcie_cfg_ctrl u_pcie_cfg_ctrl (
			// APB接口
			.pclk_div2				(pclk_div2),				// 125MHz时钟
			.apb_rst_n				(core_rst_n),				// 复位
			.p_sel					(p_sel_cfg),				// 片选
			.p_strb					(p_strb),					// 字节选通
			.p_addr					(p_addr[7:0]),				// 地址
			.p_wdata				(p_wdata),					// 写数据
			.p_ce					(p_ce),						// 时钟使能
			.p_we					(p_we),						// 写使能
			.p_rdy					(p_rdy_cfg),				// 就绪
			.p_rdata				(p_rdata_cfg),				// 读数据
			.pcie_cfg_ctrl_en		(pcie_cfg_ctrl_en),			// 配置控制使能

			// 流向PCIe控制模块
			.axis_slave_tready		(axis_slave0_tready),		// 从设备就绪
			.axis_slave_tvalid		(cfg_axis_slave0_tvalid),	// 从设备数据有效
			.axis_slave_tlast		(cfg_axis_slave0_tlast),	// 从设备帧结束
			.axis_slave_tuser		(cfg_axis_slave0_tuser),	// 从设备用户自定义信号
			.axis_slave_tdata		(cfg_axis_slave0_tdata),	// 从设备数据

			.axis_master_tready		(axis_master_tready_cfg),	// 主机就绪
			.axis_master_tvalid		(axis_master_tvalid),		// 主机数据有效
			.axis_master_tlast		(axis_master_tlast),		// 主机帧结束

			.axis_master_tkeep		(axis_master_tkeep),		// 主机数据有效字节

			.axis_master_tdata		(axis_master_tdata)			// 主机数据
		);

		// 数据流多路选择逻辑
		assign axis_slave0_tvalid      = pcie_cfg_ctrl_en ? cfg_axis_slave0_tvalid  : dma_axis_slave0_tvalid;
		assign axis_slave0_tlast       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tlast   : dma_axis_slave0_tlast;
		assign axis_slave0_tuser       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tuser   : dma_axis_slave0_tuser;
		assign axis_slave0_tdata       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tdata   : dma_axis_slave0_tdata;

		assign axis_master_tvalid_mem  = pcie_cfg_ctrl_en ? 1'b0                    : axis_master_tvalid;
		assign axis_master_tdata_mem   = pcie_cfg_ctrl_en ? 128'b0                  : axis_master_tdata;
		assign axis_master_tkeep_mem   = pcie_cfg_ctrl_en ? 4'b0                    : axis_master_tkeep;
		assign axis_master_tlast_mem   = pcie_cfg_ctrl_en ? 1'b0                    : axis_master_tlast;
		assign axis_master_tuser_mem   = pcie_cfg_ctrl_en ? 8'b0                    : axis_master_tuser;

		assign axis_master_tready      = pcie_cfg_ctrl_en ? axis_master_tready_cfg  : axis_master_tready_mem;
	end else begin:ep  // EP模式
		assign p_rdy_cfg               = 1'b0;
		assign p_rdata_cfg             = 32'b0;

		assign axis_slave0_tvalid      = dma_axis_slave0_tvalid ; //fpga向rk主机输入
		assign axis_slave0_tlast       = dma_axis_slave0_tlast;
		assign axis_slave0_tuser       = dma_axis_slave0_tuser;
		assign axis_slave0_tdata       = dma_axis_slave0_tdata;

		assign axis_master_tvalid_mem  = axis_master_tvalid;
		assign axis_master_tdata_mem   = axis_master_tdata;
		assign axis_master_tkeep_mem   = axis_master_tkeep;
		assign axis_master_tlast_mem   = axis_master_tlast;
		assign axis_master_tuser_mem   = axis_master_tuser;

		assign axis_master_tready      = axis_master_tready_mem;
	end
endgenerate

// PCIe IP顶层封装 基地址：0x0000~6000 PCIe基地址：0x7000
pcie_test u_ips2l_pcie_wrap (
	.button_rst_n				(sync_button_rst_n),	// 同步按键复位
	.power_up_rst_n				(sync_perst_n),			// 上电同步复位
	.perst_n					(sync_perst_n),			// 硬件复位

	// 时钟与复位信号
	.pclk						(pclk),					// 用户时钟
	.pclk_div2					(pclk_div2),			// 用户二分频时钟
	.ref_clk					(ref_clk),				// 参考时钟
	.ref_clk_n					(ref_clk_n),			// 参考时钟负端
	.ref_clk_p					(ref_clk_p),			// 参考时钟正端
	.core_rst_n					(core_rst_n),			// 内核复位

	// APB配置接口
	.p_sel						(p_sel_pcie),			// 片选
	.p_strb						(uart_p_strb),			// 字节选通
	.p_addr						(uart_p_addr),			// 地址
	.p_wdata					(uart_p_wdata),			// 写数据
	.p_ce						(uart_p_ce),			// 时钟使能
	.p_we						(uart_p_we),			// 写使能
	.p_rdy						(p_rdy_pcie),			// 就绪
	.p_rdata					(p_rdata_pcie),			// 读数据

	// PHY差分信号
	.rxn						(rxn),					// 接收负端
	.rxp						(rxp),					// 接收正端
	.txn						(txn),					// 发送负端
	.txp						(txp),					// 发送正端
	.pcs_nearend_loop			({4{1'b0}}),			// PCS近端环回控制
	.pma_nearend_ploop			({4{1'b0}}),			// PMA近端公共环回
	.pma_nearend_sloop			({4{1'b0}}),			// PMA近端远端环回

	// AXI4-Stream主机接口
	.axis_master_tvalid			(axis_master_tvalid),	// 主机数据有效
	.axis_master_tready			(axis_master_tready),	// 主机就绪
	.axis_master_tdata			(axis_master_tdata),	// 主机数据
	.axis_master_tkeep			(axis_master_tkeep),	// 主机数据有效字节

	.axis_master_tlast			(axis_master_tlast),	// 主机帧结束
	.axis_master_tuser			(axis_master_tuser),	// 主机用户自定义信号

	// AXI4-Stream从设备0接口
	.axis_slave0_tready			(axis_slave0_tready),	// 从设备0就绪 向fpga输入
	.axis_slave0_tvalid			(axis_slave0_tvalid),	// 从设备0数据有效 fpga向rk主机输入
	.axis_slave0_tdata			(axis_slave0_tdata),	// 从设备0数据
	.axis_slave0_tlast			(axis_slave0_tlast),	// 从设备0帧结束
	.axis_slave0_tuser			(axis_slave0_tuser),	// 从设备0用户自定义信号

	// AXI4-Stream从设备1接口
	.axis_slave1_tready			(axis_slave1_tready),	// 从设备1就绪
	.axis_slave1_tvalid			(axis_slave1_tvalid),	// 从设备1数据有效
	.axis_slave1_tdata			(axis_slave1_tdata),	// 从设备1数据
	.axis_slave1_tlast			(axis_slave1_tlast),	// 从设备1帧结束
	.axis_slave1_tuser			(axis_slave1_tuser),	// 从设备1用户自定义信号

	// AXI4-Stream从设备2接口
	.axis_slave2_tready			(axis_slave2_tready),	// 从设备2就绪
	.axis_slave2_tvalid			(axis_slave2_tvalid),	// 从设备2数据有效
	.axis_slave2_tdata			(axis_slave2_tdata),	// 从设备2数据
	.axis_slave2_tlast			(axis_slave2_tlast),	// 从设备2帧结束
	.axis_slave2_tuser			(axis_slave2_tuser),	// 从设备2用户自定义信号

	.pm_xtlh_block_tlp			(),						// 电源管理阻塞TLP

	.cfg_send_cor_err_mux		(),						// 发送正确错误
	.cfg_send_nf_err_mux		(),						// 发送非致命错误
	.cfg_send_f_err_mux			(),						// 发送致命错误
	.cfg_sys_err_rc				(),						// RC系统错误
	.cfg_aer_rc_err_mux			(),						// 高级错误报告

	// 读完成超时
	.radm_cpl_timeout			(),						// 读完成超时

	// 配置信号
	.cfg_max_rd_req_size		(cfg_max_rd_req_size),	// 最大读请求大小
	.cfg_bus_master_en			(),						// 总线主设备使能
	.cfg_max_payload_size		(cfg_max_payload_size),	// 最大有效载荷大小
	.cfg_ext_tag_en				(),						// 扩展标签使能
	.cfg_rcb					(cfg_rcb),				// 读完成边界
	.cfg_mem_space_en			(),						// 内存空间使能
	.cfg_pm_no_soft_rst			(),						// 电源管理无软复位
	.cfg_crs_sw_vis_en			(),						// 配置请求状态软件可见
	.cfg_no_snoop_en			(),						// 非监听使能
	.cfg_relax_order_en			(),						// 松弛排序使能
	.cfg_tph_req_en				(),						// TPH请求使能
	.cfg_pf_tph_st_mode			(),						// 物理功能TPH模式
	.rbar_ctrl_update			(),						//  BAR控制更新
	.cfg_atomic_req_en			(),						// 原子操作请求使能

	.cfg_pbus_num				(cfg_pbus_num),			// 总线编号
	.cfg_pbus_dev_num			(cfg_pbus_dev_num),		// 设备编号

	// 调试信号
	.radm_idle					(),						// 读请求空闲
	.radm_q_not_empty			(),						// 读请求队列非空
	.radm_qoverflow				(),						// 读请求队列溢出
	.diag_ctrl_bus				(2'b0),					// 诊断控制总线
	.cfg_link_auto_bw_mux		(),						// 链路自动带宽
	.cfg_bw_mgt_mux				(),						// 带宽管理
	.cfg_pme_mux				(),						// 电源管理事件
	.app_ras_des_sd_hold_ltssm	(1'b0),					// 保持链路状态
	.app_ras_des_tba_ctrl		(2'b0),					// 控制信号

	.dyn_debug_info_sel			(4'b0),					// 调试信息选择
	.debug_info_mux				(),

	// 系统状态信号
	.smlh_link_up				(smlh_link_up),			// 物理层链路建立成功
	.rdlh_link_up				(rdlh_link_up),			// 数据链路层建立成功
	.smlh_ltssm_state			(smlh_ltssm_state)		// 链路状态机状态
);

endmodule
