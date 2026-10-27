
//////////////////////////////////////////////////////////////////////
////                                                              ////
//// serialInterface.v                                                 ////
////                                                              ////
//// This file is part of the i2cSlave opencores effort.          ////
////                                                              ////
//// Module Description:                                          ////
//// Perform all serial to parallel, and parallel
//// to serial conversions. Perform device address matching
//// Handle arbitrary length I2C reads terminated by NAK
//// from host, and arbitrary length I2C writes terminated
//// by STOP from host
//// The second byte of a I2C write is always interpreted
//// as a register address, and becomes the base register address
//// for all read and write transactions.
//// I2C WRITE:    devAddr, regAddr, data[regAddr], data[regAddr+1], ..... data[regAddr+N]
//// I2C READ:    data[regAddr], data[regAddr+1], ..... data[regAddr+N]
//// Note that when regAddR reaches 255 it will automatically wrap round to 0
////                                                              ////
//// To Do:                                                       ////
////
////                                                              ////
//// Author(s):                                                   ////
//// - Steve Fielding, sfielding@base2designs.com                 ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
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
//     完成串行转并行、并行转串行的全部转换。
//     完成从机地址（device address）的匹配。
//     支持主机（host）以 NAK 结束的任意长度 I2C 读操作，
//     以及主机以 STOP 结束的任意长度 I2C 写操作。
//     I2C 写操作的第二个字节始终被解释为寄存器地址，并作为后续所有
//     读、写事务的基址（起始寄存器地址）。
//     I2C 写格式：devAddr, regAddr, data[regAddr], data[regAddr+1], ..... data[regAddr+N]
//     I2C 读格式：data[regAddr], data[regAddr+1], ..... data[regAddr+N]
//     注意：当 regAddr 递增到 255 后会自动回绕到 0。
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

module rk_iic_serial #(parameter [6:0] I2C_ADDRESS = 7'h66) (clearStartStopDet, clk, dataIn, dataOut, regAddr, rst, pointer_rst, scl, sdaIn, sdaOut, startStopDetState, writeEn);
localparam WRITE_CHK_LOOP_FIN = 4'b1001;
localparam STREAM_WRITE_ADDR = 2'b10;
localparam STREAM_WRITE_DATA = 2'b11;
localparam READ_CHK_LOOP_FIN = 4'b0100;
localparam WRITE_CLR_ST_STOP = 4'b1111;
localparam WRITE_LOOP_WT_LO = 4'b1010;
localparam WRITE_ST_LOOP = 4'b1011;
localparam READ_RD_LOOP = 4'b0010;
localparam WRITE_WT_LO2 = 4'b1100;
localparam WRITE_WT_HI2 = 4'b1101;
localparam WRITE_CLR_WR = 4'b1110;
localparam STREAM_IDLE = 2'b00;
localparam STREAM_READ = 2'b01;
localparam READ_WT_ACK = 4'b0110;
localparam WRITE_WT_LO = 4'b0111;
localparam WRITE_WT_HI = 4'b1000;
localparam READ_WT_HI = 4'b0011;
localparam READ_WT_LO = 4'b0101;
localparam START_DET = 2'b01;
localparam CHK_RD_WR = 4'b0001;
localparam NULL_DET = 2'b00;
localparam STOP_DET = 2'b10;
localparam I2C_NAK = 1'b1;
localparam I2C_ACK = 1'b0;
localparam START = 4'b0000;

input   clk;
input   [7:0]dataIn;
input   rst;
input   pointer_rst; // 只由硬件复位驱动；遇到重复起始（repeated START）时必须保留寄存器索引。
input   scl;
input   sdaIn;
input   [1:0]startStopDetState;
output  clearStartStopDet;
output  [7:0]dataOut;
output  [7:0]regAddr;
output  sdaOut;
output  writeEn;

reg     clearStartStopDet, next_clearStartStopDet;
wire    clk;
wire    [7:0]dataIn;
reg     [7:0]dataOut, next_dataOut;
reg     [7:0]regAddr, next_regAddr;
wire    rst;
wire    scl;
wire    sdaIn;
reg     sdaOut, next_sdaOut;
wire    [1:0]startStopDetState;
reg     writeEn, next_writeEn;

// 状态图（diagram）信号声明
reg  [2:0]bitCnt, next_bitCnt;
reg  [7:0]rxData, next_rxData;
reg  [1:0]streamSt, next_streamSt;
reg  [7:0]txData, next_txData;

// 二进制编码状态机：SISt
// 各状态编码的定义（对应上方 localparam）：

reg [3:0]CurrState_SISt, NextState_SISt;

// 状态图动作（此处只允许连续赋值：assign ...）
// 状态图动作（空）


// 状态机：SISt

// 次态逻辑（组合逻辑）
always @ (startStopDetState or streamSt or scl or txData or bitCnt or rxData or sdaIn or regAddr or dataIn or sdaOut or writeEn or dataOut or clearStartStopDet or CurrState_SISt)
begin
  NextState_SISt <= CurrState_SISt;
  // 为各输出与信号设置默认值
  next_streamSt <= streamSt;
  next_txData <= txData;
  next_rxData <= rxData;
  next_sdaOut <= sdaOut;
  next_writeEn <= writeEn;
  next_dataOut <= dataOut;
  next_bitCnt <= bitCnt;
  next_clearStartStopDet <= clearStartStopDet;
  next_regAddr <= regAddr;
  case (CurrState_SISt)  // synopsys parallel_case full_case
    START:
    begin
      next_streamSt <= STREAM_IDLE;
      next_txData <= 8'h00;
      next_rxData <= 8'h00;
      next_sdaOut <= 1'b1;
      next_writeEn <= 1'b0;
      next_dataOut <= 8'h00;
      next_bitCnt <= 3'b000;
      next_clearStartStopDet <= 1'b0;
      NextState_SISt <= CHK_RD_WR;
    end
    CHK_RD_WR:
    begin
      if (streamSt == STREAM_READ)
      begin
        NextState_SISt <= READ_RD_LOOP;
        next_txData <= dataIn;
        next_regAddr <= regAddr + 1'b1;
        next_bitCnt <= 3'b001;
      end
      else
      begin
        NextState_SISt <= WRITE_WT_HI;
        next_rxData <= 8'h00;
      end
    end
    READ_RD_LOOP:
    begin
      if (scl == 1'b0)
      begin
        NextState_SISt <= READ_WT_HI;
        next_sdaOut <= txData [7];
        next_txData <= {txData [6:0], 1'b0};
      end
    end
    READ_WT_HI:
    begin
      if (scl == 1'b1)
      begin
        NextState_SISt <= READ_CHK_LOOP_FIN;
      end
    end
    READ_CHK_LOOP_FIN:
    begin
      if (bitCnt == 3'b000)
      begin
        NextState_SISt <= READ_WT_LO;
      end
      else
      begin
        NextState_SISt <= READ_RD_LOOP;
        next_bitCnt <= bitCnt + 1'b1;
      end
    end
    READ_WT_LO:
    begin
      if (scl == 1'b0)
      begin
        NextState_SISt <= READ_WT_ACK;
        next_sdaOut <= 1'b1;
      end
    end
    READ_WT_ACK:
    begin
      if (scl == 1'b1)
      begin
        NextState_SISt <= CHK_RD_WR;
        if (sdaIn == I2C_NAK)
        next_streamSt <= STREAM_IDLE;
      end
    end
    WRITE_WT_LO:
    begin
      if ((scl == 1'b0) && (startStopDetState == STOP_DET ||
        (streamSt == STREAM_IDLE && startStopDetState == NULL_DET)))
      begin
        NextState_SISt <= WRITE_CLR_ST_STOP;
        case (startStopDetState)
        NULL_DET:
        next_bitCnt <= bitCnt + 1'b1;
        START_DET: begin
        next_streamSt <= STREAM_IDLE;
        next_rxData <= 8'h00;
        end
        default: ;
        endcase
        next_streamSt <= STREAM_IDLE;
        next_clearStartStopDet <= 1'b1;
      end
      else if (scl == 1'b0)
      begin
        NextState_SISt <= WRITE_ST_LOOP;
        case (startStopDetState)
        NULL_DET:
        next_bitCnt <= bitCnt + 1'b1;
        START_DET: begin
        next_streamSt <= STREAM_IDLE;
        next_rxData <= 8'h00;
        end
        default: ;
        endcase
      end
    end
    WRITE_WT_HI:
    begin
      if (scl == 1'b1)
      begin
        NextState_SISt <= WRITE_WT_LO;
        next_rxData <= {rxData [6:0], sdaIn};
        next_bitCnt <= 3'b000;
      end
    end
    WRITE_CHK_LOOP_FIN:
    begin
      if (bitCnt == 3'b111)
      begin
        NextState_SISt <= WRITE_CLR_WR;
        next_sdaOut <= I2C_ACK;
        case (streamSt)
        STREAM_IDLE: begin
        if (rxData[7:1] == I2C_ADDRESS &&
        startStopDetState == START_DET) begin
        if (rxData[0] == 1'b1)
        next_streamSt <= STREAM_READ;
        else
        next_streamSt <= STREAM_WRITE_ADDR;
        end
        else
        next_sdaOut <= I2C_NAK;
        end
        STREAM_WRITE_ADDR: begin
        next_streamSt <= STREAM_WRITE_DATA;
        next_regAddr <= rxData;
        end
        STREAM_WRITE_DATA: begin
        next_dataOut <= rxData;
        next_writeEn <= 1'b1;
        end
        default:
        next_streamSt <= streamSt;
        endcase
      end
      else
      begin
        NextState_SISt <= WRITE_ST_LOOP;
        next_bitCnt <= bitCnt + 1'b1;
      end
    end
    WRITE_LOOP_WT_LO:
    begin
      if (scl == 1'b0)
      begin
        NextState_SISt <= WRITE_CHK_LOOP_FIN;
      end
    end
    WRITE_ST_LOOP:
    begin
      if (scl == 1'b1)
      begin
        NextState_SISt <= WRITE_LOOP_WT_LO;
        next_rxData <= {rxData [6:0], sdaIn};
      end
    end
    WRITE_WT_LO2:
    begin
      if (scl == 1'b0)
      begin
        NextState_SISt <= CHK_RD_WR;
        next_sdaOut <= 1'b1;
      end
    end
    WRITE_WT_HI2:
    begin
      next_clearStartStopDet <= 1'b0;
      if (scl == 1'b1)
      begin
        NextState_SISt <= WRITE_WT_LO2;
      end
    end
    WRITE_CLR_WR:
    begin
      if (writeEn == 1'b1)
      next_regAddr <= regAddr + 1'b1;
      next_writeEn <= 1'b0;
      next_clearStartStopDet <= 1'b1;
      NextState_SISt <= WRITE_WT_HI2;
    end
    WRITE_CLR_ST_STOP:
    begin
      next_clearStartStopDet <= 1'b0;
      NextState_SISt <= CHK_RD_WR;
    end
  endcase
end

// 现态逻辑（时序逻辑）
always @ (posedge clk)
begin
  if (rst == 1'b1)
    CurrState_SISt <= START;
  else
    CurrState_SISt <= NextState_SISt;
end

// 输出寄存逻辑
always @ (posedge clk)
begin
  if (rst == 1'b1)
  begin
    sdaOut <= 1'b1;
    writeEn <= 1'b0;
    dataOut <= 8'h00;
    clearStartStopDet <= 1'b0;
    if (pointer_rst) regAddr <= 8'h00;
    streamSt <= STREAM_IDLE;
    txData <= 8'h00;
    rxData <= 8'h00;
    bitCnt <= 3'b000;
  end
  else
  begin
    sdaOut <= next_sdaOut;
    writeEn <= next_writeEn;
    dataOut <= next_dataOut;
    clearStartStopDet <= next_clearStartStopDet;
    regAddr <= next_regAddr;
    streamSt <= next_streamSt;
    txData <= next_txData;
    rxData <= next_rxData;
    bitCnt <= next_bitCnt;
  end
end

endmodule
