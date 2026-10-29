//////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library:
// Filename:ips2l_pcie_dma_mwr_tx_ctrl.v
//////////////////////////////////////////////////////////////////////////////
module ips2l_pcie_dma_mwr_tx_ctrl #(
    parameter                           DEVICE_TYPE = 3'd0          //3'd0:EP,3'd1:Legacy EP,3'd4:RC
)(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
    //from dma controller
    input                               i_user_define_data_flag ,

    input                               i_mwr32_req             ,
    output  reg                         o_mwr32_req_ack         ,
    input                               i_mwr64_req             ,
    output  reg                         o_mwr64_req_ack         ,

    // 原始代码: input           [9:0]               i_req_length            ,
    //++ [改动] 20位，支持大帧传输
    input           [19:0]              i_req_length            ,
    //-- [改动] 结束
    input           [63:0]              i_req_addr              ,
    input           [31:0]              i_req_data              ,
    //**********************************************************************
    //ram interface
    output  reg                         o_rd_en                 ,
    output  wire    [9:0]               o_rd_length             ,
    input                               i_gen_tlp_start         ,
    input           [127:0]             i_rd_data               ,
    input                               i_last_data             ,
    //axis_slave interface
    input                               i_axis_slave2_trdy      ,
    output  reg                         o_axis_slave2_tvld      ,
    output  reg     [127:0]             o_axis_slave2_tdata     ,
    output  reg                         o_axis_slave2_tlast     ,
    output  reg                         o_axis_slave2_tuser     ,

    output  reg                         o_mwr_tx_busy           ,
    output  wire                        o_mwr_tx_hold           ,
    output  wire                        o_mwr_tlp_tx            ,
    //debug
    input                               i_tx_restart            ,
    //++ [改动] DMA 软复位输入：重置状态机、busy、length，解除卡死
    input                               i_dma_soft_rst          ,
    //-- [改动] 结束
    //output  wire      [13:0]              o_dbg_bus


//pcie �û����������޸ģ�����
  input       [127:0]     i_user_data,        // 128λ�û�����
  input                   i_user_data_vld,    // �û�������Ч
  output wire             o_user_data_rdy,    // ��ģ��׼���ý��գ���ѹ�źţ�
  input                   i_user_data_last,   // ��ǰTLP���һ������
  //++ [改动] FIFO数据充足信号：FIFO有>=8条目时为1，用于门控TLP发起
  input                   i_fifo_data_sufficient
  //-- [改动] 结束

);
localparam      IDLE        = 2'd0;
localparam      HEADER_TX   = 2'd1;
localparam      DATA_TX     = 2'd2;

reg     [63:0]  mwr_addr;
reg     [31:0]  mwr_data;
wire    [9:0]   mwr_length_tx;

wire            mwr_req_start;
reg             mwr_req_start_ff;
// 原始代码: reg     [9:0]   mwr_length;
//++ [改动] 20位，容纳完整帧长度
reg     [19:0]  mwr_length;
//-- [改动] 结束

reg             mwr32_req_tx;
reg             mwr64_req_tx;

reg     [1:0]   state;
reg     [1:0]   next_state;

wire            mwr_req_rcv;
//tlp_tx
wire    [15:0]  requester_id;
reg     [7:0]   tag;
wire    [2:0]   fmt;
wire    [4:0]   tlp_type;
wire    [2:0]   tc;
wire    [2:0]   attr;
wire            th;
wire            td;
wire            ep;
wire    [1:0]   at;
wire    [31:0]  mwr_header_tx;

wire    [3:0]   first_dwbe;
wire    [3:0]   last_dwbe;
wire    [7:0]   dwbe;

wire            data_vlad;

wire            mwr_req_ack;

wire            tx_done;

wire [9:0]      max_payload_size;

//++ [改动] 新增：用户数据节拍计数器信号声明
reg  [7:0]      user_beat_cnt;
reg  [7:0]      user_beat_total;
wire            user_data_last_gen;
//-- [改动] 结束





//when i_axis_slave2_trdy down,hold all tx logic
assign o_mwr_tx_hold  = ~i_axis_slave2_trdy && o_axis_slave2_tvld;

assign mwr_req_rcv = i_mwr32_req || i_mwr64_req;

assign mwr_req_ack = o_mwr32_req_ack || o_mwr64_req_ack;

assign data_vlad = i_gen_tlp_start;

assign tx_done  = o_axis_slave2_tlast && i_axis_slave2_trdy && o_axis_slave2_tvld;

assign mwr_req_start = mwr_req_rcv && mwr_req_ack;

assign max_payload_size = (i_cfg_max_payload_size == 3'd0) ? 10'h20 :
                          (i_cfg_max_payload_size == 3'd1) ? 10'h40 :
                          (i_cfg_max_payload_size == 3'd2) ? 10'h80 :
                          (i_cfg_max_payload_size == 3'd3) ? 10'h100 : 10'd20;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_req_start_ff <= 1'b0;
    else
        mwr_req_start_ff <= mwr_req_start;
end

//get tlp information
//length > 128byte
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        // 原始代码: mwr_length <= 10'd0;
        //++ [改动] 20位复位
        mwr_length <= 20'd0;
        //-- [改动] 结束
    // [暂时禁用] else if(i_dma_soft_rst)
    //     mwr_length <= 20'd0;
    else if(mwr_req_start && !o_mwr_tx_busy)
        mwr_length <= i_req_length;
    else if(mwr_length >  max_payload_size && state == HEADER_TX && !o_mwr_tx_hold) //header tx
        mwr_length <= mwr_length - max_payload_size;
    else if(mwr_length <= max_payload_size && state == HEADER_TX && !o_mwr_tx_hold)
        mwr_length <= 20'd0;
end

//the true length to be transmitted
assign mwr_length_tx = (mwr_length > max_payload_size) ? max_payload_size : mwr_length ;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_addr <= 64'd0;
    else if(mwr_req_start && !o_mwr_tx_busy)
        mwr_addr <= i_req_addr;
    else if(|mwr_length && tx_done)
        mwr_addr <= mwr_addr + {52'b0,max_payload_size,2'b0};
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_data <= 32'd0;
    else if(mwr_req_start && !o_mwr_tx_busy)
        mwr_data <= i_req_data;
end

//rd ram ctrl
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_rd_en <= 1'b0;
    else if(tx_done)
        o_rd_en <= 1'b0;
    else if(|mwr_length && ~i_user_define_data_flag)
        o_rd_en <= 1'b1;
end

assign o_rd_length = mwr_length_tx;

//++ [改动] 新增：用户数据节拍计数器，根据TLP长度自动生成last信号
//   mwr_length_tx单位为DWORD，128位总线每拍传4个DWORD
//   在HEADER_TX锁存本TLP总拍数，DATA_TX中计数，到最后一拍产生last
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        user_beat_total <= 8'd1;
    else if(state == HEADER_TX && !o_mwr_tx_hold && i_user_define_data_flag)
        user_beat_total <= (mwr_length_tx[1:0] != 2'b00) ?
                           (mwr_length_tx[9:2] + 8'd1) : mwr_length_tx[9:2];
end

// [改动] 2026-05-05: 移除 && i_user_data_vld 门控，beat计数器在DATA_TX无条件推进
// 原因：若pipeline因帧复位被清空，i_user_data_vld=0时计数器停止，TLP永远无法结束
// 修复后：beat按时钟推进，不足的拍填零(见DATA_TX输出逻辑)，TLP按时完成
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        user_beat_cnt <= 8'd0;
    else if(state != DATA_TX)
        user_beat_cnt <= 8'd0;
    else if(!o_mwr_tx_hold && i_user_define_data_flag)
        user_beat_cnt <= user_beat_cnt + 8'd1;
end

assign user_data_last_gen = (user_beat_cnt == user_beat_total - 8'd1);
//-- [改动] 结束

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr32_req_tx <= 1'b0;
    // [暂时禁用] else if(i_dma_soft_rst)
    //     mwr32_req_tx <= 1'b0;
    else if(tx_done && ~(|mwr_length))
        mwr32_req_tx <= 1'b0;
    else if(mwr_req_start)
        mwr32_req_tx <= i_mwr32_req;
end
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr64_req_tx <= 1'b0;
    // [暂时禁用] else if(i_dma_soft_rst)
    //     mwr64_req_tx <= 1'b0;
    else if(tx_done && ~(|mwr_length))
        mwr64_req_tx <= 1'b0;
    else if(mwr_req_start)
        mwr64_req_tx <= i_mwr64_req;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tag <= 8'b0;
    else if(tx_done)
        tag <= tag + 8'b1;
end

//tlp header
assign requester_id     = {i_cfg_pbus_num,i_cfg_pbus_dev_num,3'b0};
assign {fmt,tlp_type}   = mwr32_req_tx ? 8'h40
                        : mwr64_req_tx ? 8'h60 : 8'h40;
assign tc               = 3'b0;
assign attr             = 3'b0;
assign {th,td,ep,at}    = 5'b0;
assign mwr_header_tx    = {fmt,tlp_type,1'b0,tc,1'b0,attr[2],1'b0,th,td,ep,attr[1:0],at,mwr_length_tx};

assign first_dwbe       = 4'hf;
assign last_dwbe        = mwr_length_tx == 10'h1 ? 4'h0 : 4'hf;
assign dwbe             = {last_dwbe,first_dwbe};

//mwr_tx
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        state <= IDLE;
    // [暂时禁用] else if(i_dma_soft_rst)
    //     state <= IDLE;
    else
        state <= next_state;
end

//++ [改动] FIFO数据充足门控：防止TLP数据中断导致PCIe IP丢包
// 最后一个TLP(mwr_length<=max_payload_size)放行，防止帧尾卡死
wire is_last_tlp = (|mwr_length) && (mwr_length <= max_payload_size);
wire fifo_gate_ok = !i_user_define_data_flag || i_fifo_data_sufficient || is_last_tlp;
//-- [改动] 结束

always @(*)
begin
    case(state)
        IDLE:
        begin
            // 原始代码: if(((mwr_req_start_ff && i_user_define_data_flag) || i_gen_tlp_start) && i_axis_slave2_trdy)
            //++ [改动] 添加用户数据模式多TLP重触发条件 + FIFO数据充足门控
            if(((mwr_req_start_ff && i_user_define_data_flag)
                || i_gen_tlp_start
                || (|mwr_length && o_mwr_tx_busy && i_user_define_data_flag)
               ) && i_axis_slave2_trdy && fifo_gate_ok)
            //-- [改动] 结束
                next_state = HEADER_TX;
            else
                next_state = IDLE;
        end
        HEADER_TX:
        begin
            if(i_axis_slave2_trdy)
                next_state = DATA_TX;
            else
                next_state = state;
        end
        DATA_TX:
        begin
       // [改动] 2026-05-05: 移除 && i_user_data_vld，由beat计数器驱动完成
        if(((i_user_define_data_flag && user_data_last_gen) ||
          i_last_data) && !o_mwr_tx_hold)
          next_state = IDLE;
        else
          next_state = state;
        end
        default:
        begin
            next_state = IDLE;
        end
    endcase
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        o_axis_slave2_tdata <= 128'b0;
        o_axis_slave2_tvld  <= 1'b0;
        o_axis_slave2_tuser <= 1'b0;
        o_axis_slave2_tlast <= 1'b0;
    end
    // [暂时禁用] DMA软复位清除AXI-S输出，防止hold状态下tvld卡高
    // else if(i_dma_soft_rst)
    // begin
    //     o_axis_slave2_tdata <= 128'b0;
    //     o_axis_slave2_tvld  <= 1'b0;
    //     o_axis_slave2_tuser <= 1'b0;
    //     o_axis_slave2_tlast <= 1'b0;
    // end
    else if(!o_mwr_tx_hold)
    begin
        case(state)
        IDLE:
        begin
            o_axis_slave2_tdata <= 128'b0;
            o_axis_slave2_tvld  <= 1'b0;
            o_axis_slave2_tuser <= 1'b0;
            o_axis_slave2_tlast <= 1'b0;
        end
        HEADER_TX:
        begin
            o_axis_slave2_tvld  <= 1'b1;
            o_axis_slave2_tlast <= 1'b0;

            if(mwr32_req_tx)
                o_axis_slave2_tdata <= {{mwr_addr[31:2],2'b0},requester_id,tag,dwbe,mwr_header_tx};
            else if(mwr64_req_tx)
                o_axis_slave2_tdata <= {{mwr_addr[31:2],2'b0},mwr_addr[63:32],requester_id,tag,dwbe,mwr_header_tx};
        end
        DATA_TX:
        begin

/*ԭ���룺ֻ��һ��32λ
                o_axis_slave2_tvld  <= 1'b1;
                o_axis_slave2_tdata <= endian_convert({96'b0,mwr_data});
                o_axis_slave2_tlast <= 1'b1;
*/ 
//��Ϊ������128λ��ʽ����

         // [改动] 2026-05-05: DATA_TX阶段tvld恒为1，防止mid-TLP数据中断
         // pipeline有数据时输出真实像素，无数据时填零(安全垫)
         if(i_user_define_data_flag) begin
          o_axis_slave2_tvld  <= 1'b1;
          // 原始代码: o_axis_slave2_tdata <= i_user_data_vld ? endian_convert(i_user_data) : 128'd0;
          //++ [改动D] *** 已恢复(改动I) ***
          // 原改动D错误地去掉了endian_convert，理由是"用户数据已为LE字节序"。
          // 实测证明Pango PCIe IP使用标准PCIe大端DWORD字节映射(tdata[31:24]→byte0)，
          // 需要endian_convert做LE→BE转换。去掉后:
          //   FPGA发0xF800(红) → host读0x00F8(蓝)；像素对{P1,P0}也被颠倒。
          // 恢复原始endian_convert调用。
          o_axis_slave2_tdata <= i_user_data_vld ? endian_convert(i_user_data) : 128'd0;
          //-- [改动D/I] 结束
          o_axis_slave2_tlast <= user_data_last_gen;

            end
            else
            begin
                o_axis_slave2_tvld  <= data_vlad;
                o_axis_slave2_tdata <= endian_convert(i_rd_data);
                if(i_last_data)
                    o_axis_slave2_tlast <= 1'b1;
            end
        end
        default:
        begin
            o_axis_slave2_tdata <= 128'b0;
            o_axis_slave2_tvld  <= 1'b0;
            o_axis_slave2_tuser <= 1'b0;
            o_axis_slave2_tlast <= 1'b0;
        end
        endcase
    end
end




 // ����assign��������DATA_TX��flag=1ʱ����֪�ⲿ����������
 assign o_user_data_rdy = (state == DATA_TX) && i_user_define_data_flag
                           && i_axis_slave2_trdy;




always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr_tx_busy <= 1'b0;
    // [暂时禁用] else if(i_dma_soft_rst)
    //     o_mwr_tx_busy <= 1'b0;
    else if(~(|mwr_length) && tx_done)
        o_mwr_tx_busy <= 1'b0;
    else if(mwr_req_start)
        o_mwr_tx_busy <= 1'b1;
end

//ack
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr32_req_ack <= 1'b0;
    else if(!i_mwr32_req)
        o_mwr32_req_ack <= 1'b0;
    else if(i_mwr32_req && !o_mwr_tx_busy)
        o_mwr32_req_ack <= 1'b1;
end





always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr64_req_ack <= 1'b0;
    else if(!i_mwr64_req)
        o_mwr64_req_ack <= 1'b0;
    else if(i_mwr64_req && !o_mwr_tx_busy)
        o_mwr64_req_ack <= 1'b1;
end

assign o_mwr_tlp_tx = state == DATA_TX;

//******************************************************************debug*************************************************************************
//check for 128byte only
wire            tlp_tx_vld;
reg             tlp_data_tx;
reg     [2:0]   tlp_data_cnt;
reg     [13:0]  tlp_tx_sum;

assign tlp_tx_vld = i_axis_slave2_trdy && o_axis_slave2_tvld;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tlp_data_tx <= 1'b0;
    else if(state == DATA_TX)
        tlp_data_tx <= 1'b1;
    else if(tlp_tx_vld)
        tlp_data_tx <= 1'b0;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tlp_data_cnt <= 3'b0;
    else if(tx_done)
        tlp_data_cnt <= 3'b0;
    else if(tlp_data_tx && tlp_tx_vld)
        tlp_data_cnt <= tlp_data_cnt + 3'b1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tlp_tx_sum <= 14'b0;
    else if(i_tx_restart)
        tlp_tx_sum <= 14'b0;
    else if(tx_done)
        tlp_tx_sum <= tlp_tx_sum + 14'b1;
end

//debug_bus
//assign o_dbg_bus = {
//                    tlp_tx_sum  //13:0
//                    };


//convert from little endian into big endian
function [127:0] endian_convert;
   input [127:0] data_in;
   begin
   endian_convert[32*0+31:32*0+0] = {data_in[32*0+7:32*0+0], data_in[32*0+15:32*0+8], data_in[32*0+23:32*0+16], data_in[32*0+31:32*0+24]};
   endian_convert[32*1+31:32*1+0] = {data_in[32*1+7:32*1+0], data_in[32*1+15:32*1+8], data_in[32*1+23:32*1+16], data_in[32*1+31:32*1+24]};
   endian_convert[32*2+31:32*2+0] = {data_in[32*2+7:32*2+0], data_in[32*2+15:32*2+8], data_in[32*2+23:32*2+16], data_in[32*2+31:32*2+24]};
   endian_convert[32*3+31:32*3+0] = {data_in[32*3+7:32*3+0], data_in[32*3+15:32*3+8], data_in[32*3+23:32*3+16], data_in[32*3+31:32*3+24]};
   end
endfunction

endmodule