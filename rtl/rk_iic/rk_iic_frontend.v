//////////////////////////////////////////////////////////////////////
////                                                              ////
//// i2cSlave.v                                                   ////
////                                                              ////
//// This file is part of the i2cSlave opencores effort.          ////
////                                                              ////
//// Module Description:                                          ////
//// You will need to modify this file to implement your
//// interface.
////                                                              ////
//// To Do:                                                       ////
////
////                                                              ////
//// Author(s):                                                   ////
//// - Steve Fielding, sfielding@base2designs.com                 ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
////
////                                                              ////
//// This source file may be used and distributed without         ////
//// restriction provided that this copyright statement is not    ////
//// removed from the file and that any derivative work contains  ////
//// the original copyright notice and the associated disclaimer. ////
////                                                              ////
//// This source file is free software; you can redistribute it   ////
//// and/or modify it under the terms of the GNU Lesser General   ////
//// Public License as published by the Free Software Foundation; ////
//// either version 2.1 of the License, or (at your option) any   ////
//// later version.                                               ////
////                                                              ////
//// This source is distributed in the hope that it will be       ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied   ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      ////
//// PURPOSE. See the GNU Lesser General Public License for more  ////
//// details.                                                     ////
////                                                              ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
//
// 说明：上方版权与许可声明（Copyright / LGPL）保留英文原文，不做翻译，
//       以免翻译改变其法律含义。
//
// 文件头原始英文内容的中文翻译如下：
//   本文件属于 i2cSlave（OpenCores）开源工程的组成部分。
//   模块说明：
//     你需要修改本文件，才能实现你自己的接口。
//   待办事项（To Do）：无
//   作者：
//     - Steve Fielding, sfielding@base2designs.com
//   许可：本源文件可自由使用与分发，前提是保留本版权声明，且任何衍生
//         作品需附带原始版权声明及相关免责声明。本文件为自由软件，你可
//         按自由软件基金会发布的 GNU 宽通用公共许可证（LGPL）第 2.1 版
//         或（由你选择）任何更高版本的条款进行再分发和/或修改。本源码
//         系希望其有用而分发，但不提供任何担保，甚至不包含适销性或特
//         定用途适用性的默示担保。更多细节请参见 GNU 宽通用公共许可证。
//

module rk_iic_frontend #(
 parameter integer CLK_FREQ_MHZ=25,
 parameter [6:0] I2C_ADDRESS=7'h66
)(input wire clk, input wire rst, inout wire sda, input wire scl,
 output wire [7:0] reg_addr, output wire [7:0] reg_wdata,
 output wire reg_write, input wire [7:0] reg_rdata);
localparam START_DET = 2'b01;
localparam NULL_DET = 2'b00;
localparam STOP_DET = 2'b10;

localparam integer DEB_I2C_LEN = ((10*CLK_FREQ_MHZ)/100 < 2) ? 2 : (10*CLK_FREQ_MHZ)/100;
localparam integer SCL_DEL_LEN = ((10*CLK_FREQ_MHZ)/100 < 2) ? 2 : (10*CLK_FREQ_MHZ)/100;
localparam integer SDA_DEL_LEN = ((4*CLK_FREQ_MHZ)/100 < 2) ? 2 : (4*CLK_FREQ_MHZ)/100;
// 内部线网与寄存器
reg sdaDeb;
reg sclDeb;
reg [DEB_I2C_LEN-1:0] sdaPipe;
reg [DEB_I2C_LEN-1:0] sclPipe;

reg [SCL_DEL_LEN-1:0] sclDelayed;
reg [SDA_DEL_LEN-1:0] sdaDelayed;
reg [1:0] startStopDetState;
wire clearStartStopDet;
wire sdaOut;
wire sdaIn;
wire [7:0] regAddr;
wire [7:0] dataToRegIF;
wire writeEn;
wire [7:0] dataFromRegIF;
reg [1:0] rstPipe;
wire rstSyncToClk;
reg startEdgeDet;

assign sda = (sdaOut == 1'b0) ? 1'b0 : 1'bz;
assign sdaIn = sda;

// 将复位的上升沿同步到 clk 时钟域
always @(posedge clk) begin
  if (rst == 1'b1)
    rstPipe <= 2'b11;
  else
    rstPipe <= {rstPipe[0], 1'b0};
end

assign rstSyncToClk = rstPipe[1];

// 对 sda 与 scl 做去抖（两次连续采样一致才认可电平变化）
always @(posedge clk) begin
  if (rstSyncToClk == 1'b1) begin
    sdaPipe <= {DEB_I2C_LEN{1'b1}};
    sdaDeb <= 1'b1;
    sclPipe <= {DEB_I2C_LEN{1'b1}};
    sclDeb <= 1'b1;
  end
  else begin
    sdaPipe <= {sdaPipe[DEB_I2C_LEN-2:0], sdaIn};
    sclPipe <= {sclPipe[DEB_I2C_LEN-2:0], scl};
    if (&sclPipe[DEB_I2C_LEN-1:1] == 1'b1)
      sclDeb <= 1'b1;
    else if (|sclPipe[DEB_I2C_LEN-1:1] == 1'b0)
      sclDeb <= 1'b0;
    if (&sdaPipe[DEB_I2C_LEN-1:1] == 1'b1)
      sdaDeb <= 1'b1;
    else if (|sdaPipe[DEB_I2C_LEN-1:1] == 1'b0)
      sdaDeb <= 1'b0;
  end
end


// 对 scl 与 sda 做延时
// sclDelayed 用作延时后的采样时钟
// sdaDelayed 只用于起始/停止条件检测
// 由于 sda 相对 scl 下降沿的保持时间为 0ns，
// 必须让 sda 相对于 scl 具有一定延时，否则会在 scl 下降沿
// 误检出起始/停止条件。
always @(posedge clk) begin
  if (rstSyncToClk == 1'b1) begin
    sclDelayed <= {SCL_DEL_LEN{1'b1}};
    sdaDelayed <= {SDA_DEL_LEN{1'b1}};
  end
  else begin
    sclDelayed <= {sclDelayed[SCL_DEL_LEN-2:0], sclDeb};
    sdaDelayed <= {sdaDelayed[SDA_DEL_LEN-2:0], sdaDeb};
  end
end

// 起始/停止条件检测
always @(posedge clk) begin
  if (rstSyncToClk == 1'b1) begin
    startStopDetState <= NULL_DET;
    startEdgeDet <= 1'b0;
  end
  else begin
    if (sclDeb == 1'b1 && sdaDelayed[SDA_DEL_LEN-2] == 1'b0 && sdaDelayed[SDA_DEL_LEN-1] == 1'b1)
      startEdgeDet <= 1'b1;
    else
      startEdgeDet <= 1'b0;
    if (clearStartStopDet == 1'b1)
      startStopDetState <= NULL_DET;
    else if (sclDeb == 1'b1) begin
      if (sdaDelayed[SDA_DEL_LEN-2] == 1'b1 && sdaDelayed[SDA_DEL_LEN-1] == 1'b0)
        startStopDetState <= STOP_DET;
      else if (sdaDelayed[SDA_DEL_LEN-2] == 1'b0 && sdaDelayed[SDA_DEL_LEN-1] == 1'b1)
        startStopDetState <= START_DET;
    end
  end
end


assign reg_addr=regAddr;
assign reg_wdata=dataToRegIF;
assign reg_write=writeEn;
assign dataFromRegIF=reg_rdata;
rk_iic_serial #(.I2C_ADDRESS(I2C_ADDRESS)) u_serialInterface (
  .clk(clk),
  .rst(rstSyncToClk | startEdgeDet),
  .pointer_rst(rstSyncToClk),
  .dataIn(dataFromRegIF),
  .dataOut(dataToRegIF),
  .writeEn(writeEn),
  .regAddr(regAddr),
  .scl(sclDelayed[SCL_DEL_LEN-1]),
  .sdaIn(sdaDeb),
  .sdaOut(sdaOut),
  .startStopDetState(startStopDetState),
  .clearStartStopDet(clearStartStopDet)
);


endmodule


