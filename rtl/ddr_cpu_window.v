`default_nettype none
`timescale 1ns/1ps

// CPU 的 DDR 块窗口：32 位 MMIO，256 字节缓冲，独立 CPU/DDR 时钟。
// 跨域采用稳定邮箱 + 双级同步的请求/应答翻转位。请求未应答前，
// CPU 不得改写配置和窗口；DDR 应答后也保持结果，直到下一条请求到达。
// 多位邮箱不能逐位同步。上板需对邮箱总线添加跨域最大延迟约束，见文档。
// rst_n 必须同时复位 DDR IP；禁止仅复位本模块来取消原生事务。
module ddr_cpu_window #(
    parameter [31:0] DDR_LIMIT_BYTES = 32'h20000000,
    parameter integer AXI_ADDR_WIDTH = 28,
    parameter integer COLUMN_WIDTH = 10,
    parameter integer TIMEOUT_CYCLES = 4096,
    parameter integer ENABLE_AI = 0,
    parameter integer AI_ACT_WIDTH = 8,
    parameter integer ENABLE_VIDEO = 0,
    parameter integer VIDEO_FIFO_ADDR_BITS = 9
)(
    input wire clk,
    input wire core_clk,
    input wire rst_n,
    input wire ddr_init_done,
    input wire pixclk_in, vs_in, de_in,
    input wire [23:0] rgb_in,
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
    // AI、视频与CPU窗口共用一个命令邮箱及DDR所有权，忙时冻结全部配置。
    localparam [31:0] AI_CTRL=32'h30200, AI_STATUS=32'h30204, AI_INPUT=32'h30208,
        AI_WEIGHT=32'h3020c, AI_BIAS=32'h30210, AI_OUTPUT=32'h30214,
        AI_HW=32'h30218, AI_CHANNELS=32'h3021c, AI_CONV=32'h30220, AI_ERROR=32'h30224,
        AI_CYCLES=32'h30228, AI_ISSUES=32'h3022c, AI_OH=32'h30230, AI_OW=32'h30234,
        AI_POST=32'h30238, AI_QUANT=32'h3023c, AI_GROUP=32'h30240, AI_FORMAT=32'h30244, AI_OPCODE=32'h30248;
    reg [31:0] ai_input,ai_weight,ai_bias,ai_output,ai_hw,ai_channels;
    reg [6:0] ai_conv;
    reg [31:0] ai_post, ai_quant, ai_group,ai_opcode;
    reg request_ai;
    reg [31:0] cpu_cycles,cpu_issues,cpu_oh,cpu_ow;
    reg [31:0] response_cycles,response_issues,response_oh,response_ow;
    localparam [31:0] VIDEO_CTRL=32'h30300,VIDEO_STATUS=32'h30304,VIDEO_BASE=32'h30308,
        VIDEO_HW=32'h3030c,VIDEO_STRIDE=32'h30310,VIDEO_POLARITY=32'h30314,
        VIDEO_ERROR=32'h30318,VIDEO_BYTES=32'h3031c,VIDEO_TIMEOUT=32'h30320,VIDEO_FORMAT=32'h30324;
    reg request_video;
    reg [31:0] video_base,video_hw,video_stride,video_timeout,cpu_video_bytes,response_video_bytes;
    reg video_vs_active;
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
            ai_input<=0;ai_weight<=0;ai_bias<=0;ai_output<=0;ai_hw<=0;ai_channels<=0;ai_conv<=7'b0000101;
            ai_post<=0;ai_quant<=0;ai_group<=0;ai_opcode<=1;
            request_ai<=0;cpu_cycles<=0;cpu_issues<=0;cpu_oh<=0;cpu_ow<=0;
            request_video<=0;video_base<=0;video_hw<=0;video_stride<=0;
            video_timeout<=50_000_000;video_vs_active<=1;cpu_video_bytes<=0;
        end else begin
            // 完成位跨域稳定后，结果邮箱也已稳定至少两个 CPU 周期。
            if (cpu_busy && ack_sync == request_toggle) begin
                cpu_busy <= 0; cpu_done <= !response_error;
                cpu_error <= response_error; cpu_fault <= response_fault;
                cpu_code <= response_code;
                if(request_ai) begin
                    cpu_cycles<=response_cycles;cpu_issues<=response_issues;
                    cpu_oh<=response_oh;cpu_ow<=response_ow;
                end
                if(request_video) cpu_video_bytes<=response_video_bytes;
                if (!request_ai && !request_video && !direction_reg && !response_error) begin
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
                    AI_INPUT: if(ENABLE_AI!=0) ai_input<=dev_wdata;
                    AI_WEIGHT: if(ENABLE_AI!=0) ai_weight<=dev_wdata;
                    AI_BIAS: if(ENABLE_AI!=0) ai_bias<=dev_wdata;
                    AI_OUTPUT: if(ENABLE_AI!=0) ai_output<=dev_wdata;
                    AI_HW: if(ENABLE_AI!=0) ai_hw<=dev_wdata;
                    AI_CHANNELS: if(ENABLE_AI!=0) ai_channels<=dev_wdata;
                    AI_CONV: if(ENABLE_AI!=0) ai_conv<=dev_wdata[6:0];
                    AI_POST: if(ENABLE_AI!=0) ai_post<=dev_wdata;
                    AI_QUANT: if(ENABLE_AI!=0) ai_quant<=dev_wdata;
                    AI_GROUP: if(ENABLE_AI!=0) ai_group<=dev_wdata;
                    AI_OPCODE: if(ENABLE_AI!=0) ai_opcode<=dev_wdata;
                    VIDEO_BASE: if(ENABLE_VIDEO!=0) video_base<=dev_wdata;
                    VIDEO_HW: if(ENABLE_VIDEO!=0) video_hw<=dev_wdata;
                    VIDEO_STRIDE: if(ENABLE_VIDEO!=0) video_stride<=dev_wdata;
                    VIDEO_POLARITY: if(ENABLE_VIDEO!=0) video_vs_active<=dev_wdata[0];
                    VIDEO_TIMEOUT: if(ENABLE_VIDEO!=0) video_timeout<=dev_wdata;
                    CTRL,AI_CTRL,VIDEO_CTRL: if(dev_addr_wr==CTRL ||
                        (dev_addr_wr==AI_CTRL && ENABLE_AI!=0) || (dev_addr_wr==VIDEO_CTRL && ENABLE_VIDEO!=0)) begin
                        if (dev_wdata[2]) begin
                            cpu_done <= 0; cpu_error <= 0; cpu_code <= 0;
                        end
                        if (dev_wdata[0]) begin
                            cpu_done <= 0;
                            if (ready) begin
                                direction_reg <= dev_wdata[1];
                                request_ai <= dev_addr_wr==AI_CTRL;
                                request_video <= dev_addr_wr==VIDEO_CTRL;
                                if(dev_addr_wr==AI_CTRL) begin cpu_cycles<=0;cpu_issues<=0;cpu_oh<=0;cpu_ow<=0;end
                                if(dev_addr_wr==VIDEO_CTRL) cpu_video_bytes<=0;
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
            AI_STATUS: if(ENABLE_AI!=0) read_data={26'd0,init_sync,ready,cpu_fault,cpu_error,cpu_done,cpu_busy};
            AI_INPUT: if(ENABLE_AI!=0) read_data=ai_input;
            AI_WEIGHT: if(ENABLE_AI!=0) read_data=ai_weight;
            AI_BIAS: if(ENABLE_AI!=0) read_data=ai_bias;
            AI_OUTPUT: if(ENABLE_AI!=0) read_data=ai_output;
            AI_HW: if(ENABLE_AI!=0) read_data=ai_hw;
            AI_CHANNELS: if(ENABLE_AI!=0) read_data=ai_channels;
            AI_CONV: if(ENABLE_AI!=0) read_data={25'd0,ai_conv};
            AI_POST: if(ENABLE_AI!=0) read_data=ai_post;
            AI_QUANT: if(ENABLE_AI!=0) read_data=ai_quant;
            AI_GROUP: if(ENABLE_AI!=0) read_data=ai_group;
            AI_FORMAT: if(ENABLE_AI!=0) read_data=AI_ACT_WIDTH;
            AI_OPCODE: if(ENABLE_AI!=0) read_data=ai_opcode;
            AI_ERROR: if(ENABLE_AI!=0) read_data={28'd0,cpu_code};
            AI_CYCLES: if(ENABLE_AI!=0) read_data=cpu_cycles;
            AI_ISSUES: if(ENABLE_AI!=0) read_data=cpu_issues;
            AI_OH: if(ENABLE_AI!=0) read_data=cpu_oh;
            AI_OW: if(ENABLE_AI!=0) read_data=cpu_ow;
            VIDEO_STATUS: if(ENABLE_VIDEO!=0) read_data={26'd0,init_sync,ready,cpu_fault,cpu_error,cpu_done,cpu_busy};
            VIDEO_BASE: if(ENABLE_VIDEO!=0) read_data=video_base;
            VIDEO_HW: if(ENABLE_VIDEO!=0) read_data=video_hw;
            VIDEO_STRIDE: if(ENABLE_VIDEO!=0) read_data=video_stride;
            VIDEO_POLARITY: if(ENABLE_VIDEO!=0) read_data={31'd0,video_vs_active};
            VIDEO_ERROR: if(ENABLE_VIDEO!=0) read_data={28'd0,cpu_code};
            VIDEO_BYTES: if(ENABLE_VIDEO!=0) read_data=cpu_video_bytes;
            VIDEO_TIMEOUT: if(ENABLE_VIDEO!=0) read_data=video_timeout;
            VIDEO_FORMAT: if(ENABLE_VIDEO!=0) read_data=1; // 小端R/G/B/0，每像素4字节
            default: if (window_rd && !cpu_busy && valid_words[dev_addr_rd[7:2]])
                read_data = cpu_buf[dev_addr_rd[7:2]];
        endcase
    end

    localparam [2:0] C_IDLE=0, C_COMMAND=1, C_ACTIVE=2, C_AI_COMMAND=3, C_AI_ACTIVE=4,
                     C_VIDEO_COMMAND=5,C_VIDEO_ACTIVE=6;
    reg [2:0] core_state;
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
    // 所有权只在共同邮箱任务之间切换；不会在原生命令或数据拍中间抢占。
    wire owner_ai=core_state==C_AI_COMMAND || core_state==C_AI_ACTIVE;
    wire owner_video=core_state==C_VIDEO_COMMAND || core_state==C_VIDEO_ACTIVE;
    wire video_ready,video_done,video_error,video_fault;
    wire [3:0] video_code;
    wire [31:0] video_written_bytes,video_dma_addr,video_dma_len;
    wire video_dma_valid,video_dma_wr_valid;
    wire [127:0] video_dma_data;
    generate if(ENABLE_VIDEO!=0) begin : g_video
        video_frame_capture #(.FIFO_ADDR_BITS(VIDEO_FIFO_ADDR_BITS),.DDR_ADDR_WIDTH(AXI_ADDR_WIDTH)) u_capture (
            .core_clk(core_clk),.rst_n(core_reset_n),.ddr_initialized(ddr_init_done),
            .cmd_valid(core_state==C_VIDEO_COMMAND && ddr_init_done),.cmd_ready(video_ready),
            .cfg_base(video_base),.cfg_stride(video_stride),.cfg_timeout(video_timeout),
            .cfg_width(video_hw[15:0]),.cfg_height(video_hw[31:16]),.cfg_vs_active(video_vs_active),
            .done(video_done),.error(video_error),.fault(video_fault),.error_code(video_code),.written_bytes(video_written_bytes),
            .pixel_clk(pixclk_in),.pixel_vs(vs_in),.pixel_de(de_in),.pixel_rgb(rgb_in),
            .dma_cmd_valid(video_dma_valid),.dma_cmd_ready(cmd_ready && owner_video),
            .dma_cmd_addr(video_dma_addr),.dma_cmd_len(video_dma_len),
            .dma_wr_valid(video_dma_wr_valid),.dma_wr_ready(wr_ready && owner_video),.dma_wr_data(video_dma_data),
            .dma_done(transfer_done),.dma_error(transfer_error),.dma_fault(transfer_fault)
        );
    end else begin : g_no_video
        wire unused_video_inputs=^{pixclk_in,vs_in,de_in,rgb_in};
        wire [31:0] unused_video_fifo_size=VIDEO_FIFO_ADDR_BITS;
        assign video_ready=0;assign video_done=0;assign video_error=0;assign video_fault=0;assign video_code=0;
        assign video_written_bytes=0;assign video_dma_valid=0;assign video_dma_addr=0;assign video_dma_len=0;
        assign video_dma_wr_valid=0;assign video_dma_data=0;
    end endgenerate
    wire ai_ready,ai_done,ai_error,ai_busy;
    wire [3:0] ai_code;
    wire [31:0] ai_oh,ai_ow,ai_cycles,ai_issues;
    wire ai_dma_cmd_valid,ai_dma_cmd_write,ai_dma_wr_valid,ai_dma_rd_ready;
    wire [31:0] ai_dma_cmd_addr,ai_dma_cmd_len;
    wire [127:0] ai_dma_wr_data;
    wire unused_ai_busy=ai_busy;
    generate if(ENABLE_AI!=0) begin : g_ai
        conv2d_ddr_engine #(.ACT_WIDTH(AI_ACT_WIDTH)) u_engine (
            .clk(core_clk),.rst_n(core_reset_n),.cmd_valid(core_state==C_AI_COMMAND && ddr_init_done),.cmd_ready(ai_ready),
            .cfg_opcode(ai_opcode),
            .cfg_input_addr(ai_input),.cfg_weight_addr(ai_weight),.cfg_bias_addr(ai_bias),.cfg_output_addr(ai_output),
            .cfg_quant_addr(ai_quant),.cfg_post(ai_post),.cfg_group_split(ai_group),
            .cfg_in_h(ai_hw[15:0]),.cfg_in_w(ai_hw[31:16]),.cfg_in_ch(ai_channels[15:0]),.cfg_out_ch(ai_channels[31:16]),
            .cfg_kernel(ai_conv[1:0]),.cfg_stride(ai_conv[3:2]),.cfg_padding(ai_conv[5:4]),.cfg_bias_enable(ai_conv[6]),
            .clear_status(1'b0),.busy(ai_busy),.done(ai_done),.error(ai_error),.error_code(ai_code),
            .out_h(ai_oh),.out_w(ai_ow),.total_cycles(ai_cycles),.mac_issues(ai_issues),
            .dma_cmd_valid(ai_dma_cmd_valid),.dma_cmd_ready(cmd_ready && owner_ai),
            .dma_cmd_write(ai_dma_cmd_write),.dma_cmd_addr(ai_dma_cmd_addr),.dma_cmd_len(ai_dma_cmd_len),
            .dma_done(transfer_done),.dma_error(transfer_error),.dma_fault(transfer_fault),.dma_initialized(ddr_init_done),
            .dma_error_code(transfer_code),.dma_wr_valid(ai_dma_wr_valid),.dma_wr_ready(wr_ready && owner_ai),
            .dma_wr_data(ai_dma_wr_data),.dma_rd_valid(rd_valid && owner_ai),.dma_rd_ready(ai_dma_rd_ready),.dma_rd_data(rd_data)
        );
    end else begin : g_no_ai
        assign ai_ready=0;assign ai_done=0;assign ai_error=0;assign ai_code=0;assign ai_busy=0;
        assign ai_oh=0;assign ai_ow=0;assign ai_cycles=0;assign ai_issues=0;
        assign ai_dma_cmd_valid=0;assign ai_dma_cmd_write=0;assign ai_dma_cmd_addr=0;assign ai_dma_cmd_len=0;
        assign ai_dma_wr_valid=0;assign ai_dma_wr_data=0;assign ai_dma_rd_ready=0;
    end endgenerate
    integer core_i, lane;
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            core_state <= C_IDLE; core_direction <= 0; core_address <= 0; core_length <= 0;
            stream_index <= 0; ack_toggle <= 0;
            response_error <= 0; response_fault <= 0; response_code <= 0;
            response_cycles<=0;response_issues<=0;response_oh<=0;response_ow<=0;
            response_video_bytes<=0;
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
                    core_state <= request_video ? C_VIDEO_COMMAND : (request_ai ? C_AI_COMMAND : C_COMMAND);
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
                C_AI_COMMAND: begin
                    if(!ddr_init_done) begin
                        response_error<=1;response_fault<=0;response_code<=8;
                        response_cycles<=0;response_issues<=0;response_oh<=0;response_ow<=0;
                        ack_toggle<=req_sync;core_state<=C_IDLE;
                    end else if(ai_ready) core_state<=C_AI_ACTIVE;
                end
                C_AI_ACTIVE: if(ai_done || ai_error) begin
                    response_error<=ai_error;response_fault<=transfer_fault;response_code<=ai_code;
                    response_cycles<=ai_cycles;response_issues<=ai_issues;response_oh<=ai_oh;response_ow<=ai_ow;
                    ack_toggle<=req_sync;core_state<=C_IDLE;
                end
                C_VIDEO_COMMAND: begin
                    if(!ddr_init_done) begin
                        response_error<=1;response_fault<=0;response_code<=8;response_video_bytes<=0;
                        ack_toggle<=req_sync;core_state<=C_IDLE;
                    end else if(video_ready) core_state<=C_VIDEO_ACTIVE;
                end
                C_VIDEO_ACTIVE: if(video_done || video_error) begin
                    response_error<=video_error;response_fault<=video_fault || transfer_fault;response_code<=video_code;
                    response_video_bytes<=video_written_bytes;
                    ack_toggle<=req_sync;core_state<=C_IDLE;
                end
                default: core_state <= C_IDLE;
            endcase
        end
    end

    ddr_block_transfer #(
        .LIMIT_BYTES({1'b0,DDR_LIMIT_BYTES}),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .COLUMN_WIDTH(COLUMN_WIDTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_transfer (
        .core_clk(core_clk), .rst_n(core_reset_n), .ddr_init_done(ddr_init_done),
        .cmd_valid(owner_video ? video_dma_valid : (owner_ai ? ai_dma_cmd_valid : (core_state == C_COMMAND && ddr_init_done))), .cmd_ready(cmd_ready),
        .cmd_write(owner_video ? 1'b1 : (owner_ai ? ai_dma_cmd_write : core_direction)),
        .cmd_addr(owner_video ? video_dma_addr : (owner_ai ? ai_dma_cmd_addr : core_address)),
        .cmd_len(owner_video ? video_dma_len : (owner_ai ? ai_dma_cmd_len : core_length)),
        .clear_status(1'b0), .busy(unused_transfer_busy), .done(transfer_done), .error(transfer_error),
        .error_code(transfer_code), .fault(transfer_fault),
        .wr_valid(owner_video ? video_dma_wr_valid : (owner_ai ? ai_dma_wr_valid : wr_valid)), .wr_ready(wr_ready),
        .wr_data(owner_video ? video_dma_data : (owner_ai ? ai_dma_wr_data : core_buf[stream_index[3:0]])),
        .rd_valid(rd_valid), .rd_ready(owner_video ? 1'b0 : (owner_ai ? ai_dma_rd_ready : rd_ready)), .rd_data(rd_data), .rd_last(unused_rd_last),
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
