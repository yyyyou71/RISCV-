`timescale 1ns/1ps
module CSR(
    input clk,
    input rst_n,
    input stall,

    input mret_commit,
    input [11:0] CSR_addr,  // CSR 编号，不是内存地址
    input CSR_we,           // 本拍是否允许写入
    input [31:0] CSR_in,    // 准备写入的数据

    // 外设中断请求，需要外设自己保持
    input timer_irq,        // 定时器   

    input irq_accept,
    input [31:0] irq_resume_pc,

    // 中断地址和返回地址
    output [31:0] irq_entry_pc,
    output [31:0] mret_target_pc,

    // 中断请求和中断寄存器堆输出
    output reg irq_request,
    output [31:0] CSR_out   // 当前选中寄存器的值，组合读取
);
    // CSR_ADDR编号
    localparam [11:0] ADDR_MSTATUS  = 12'h300;
    localparam [11:0] ADDR_MTVEC    = 12'h305;
    localparam [11:0] ADDR_MIE      = 12'h304;
    localparam [11:0] ADDR_MIP      = 12'h344;
    localparam [11:0] ADDR_MEPC     = 12'h341;
    localparam [11:0] ADDR_MCAUSE   = 12'h342;

    // 掩码
    localparam [31:0] MIE_WRITE_MASK     = 32'h0000_0080;
    localparam [31:0] MSTATUS_WRITE_MASK = 32'h0000_0088;
    // 只实现 M-mode，MPP[12:11] 固定为 11；其余未实现字段读零。
    localparam [31:0] MSTATUS_FIXED = 32'h0000_1800;

    // CSR寄存器
    /*
        定时器：    MTIP -- bit7
        外部中断:   MEIP -- bit11    
    */
    reg [31:0] mstatus;     // 目前只开放中断总开关bit3和保存总开关的bit7
    reg [31:0] mtvec;
    reg [31:0] mie;         // 中断分类开关；本步只使用 bit7
    wire [31:0] mip;         // 各种中断请求
    reg [31:0] mepc;        // 恢复流水线的地址
    reg [31:0] mcause;      // 进入中断原因


    // 软件配置中断相关
    always @(posedge clk) begin
        if (!rst_n)begin
            mtvec <= 32'b0;
            mie <= 32'b0;  // 复位后不允许定时器中断
        end

        else if(stall)begin            
        end

        // mtvec
        else if (CSR_we && CSR_addr == ADDR_MTVEC)begin
            // mtvec分成两个部分来看，高30位是中断PC地址，低2位表示模式
            // 00:Direct 01:Vectored
            mtvec <= {CSR_in[31:2], 2'b00};
        end

        // mie
        else if (CSR_we && CSR_addr == ADDR_MIE)begin
            // 软件给出 32 位数据，但只接收当前实现的可写位。
            mie <= CSR_in & MIE_WRITE_MASK;
        end
    end

    // mstatus:处理器中断总状态
    always @(posedge clk) begin
        if(!rst_n)begin
            mstatus <= MSTATUS_FIXED;
        end

        else if(mret_commit)begin
            mstatus[3] <= mstatus[7];
            mstatus[7] <= 1'b1;
        end

        else if(irq_accept)begin
            mstatus[7] <= mstatus[3];
            mstatus[3] <= 0;
        end

        else if(stall)begin            
        end

        else if(CSR_we && CSR_addr == ADDR_MSTATUS)begin
            mstatus <= (CSR_in & MSTATUS_WRITE_MASK) | MSTATUS_FIXED;
        end      
    end

    // mepc:本次处理完返回的pc
    always @(posedge clk) begin
        if(!rst_n)begin
            mepc <= 32'b0;
        end

        else if(irq_accept)begin
            mepc <= {irq_resume_pc[31:2], 2'b00};
        end

        else if(stall)begin            
        end

        else if(CSR_we && CSR_addr == ADDR_MEPC)begin
            mepc <= {CSR_in[31:2], 2'b00};
        end
    end

    // mcause:记录进入中断原因
    always @(posedge clk) begin
        if(!rst_n)begin
            mcause <= 0;
        end

        else if(irq_accept)begin
            mcause <= {1'b1,31'h7};
        end

        else if(stall)begin            
        end

        else if(CSR_we && CSR_addr == ADDR_MCAUSE)begin
            mcause <= CSR_in;
        end
    end



    // 硬件触发中断(组合逻辑)
    assign mip = {24'b0, timer_irq, 7'b0};

    // CSR寄存器输出
    assign CSR_out = (CSR_addr == ADDR_MTVEC)   ? mtvec :
                     (CSR_addr == ADDR_MIE)     ? mie   : 
                     (CSR_addr == ADDR_MIP)     ? mip   :
                     (CSR_addr == ADDR_MSTATUS) ? mstatus :
                     (CSR_addr == ADDR_MEPC)    ? mepc : 
                     (CSR_addr == ADDR_MCAUSE)  ? mcause : 32'b0;


    assign irq_entry_pc = mtvec;
    assign mret_target_pc = mepc;

    // 对流水线中断请求
    always @(*) begin
        if(rst_n & mstatus[3] & mie[7] & mip[7])begin
            irq_request = 1'b1;
        end
        else
            irq_request = 1'b0;
    end
endmodule

/*
| CSR 编号 | 选择的寄存器 |
|---|---|
| `0x300` | `mstatus` |
| `0x304` | `mie` |
| `0x305` | `mtvec` |
| `0x341` | `mepc` |
| `0x342` | `mcause` |
| `0x344` | `mip` |

| CSR | 保存范围 |
|---|---|
| `mstatus` | CPU 的全局状态，包括中断总开关 |
| `mie` | 多个中断类别各自的允许状态 |
| `mip` | 多个中断类别各自的请求状态 |
| `mtvec` | 统一入口或向量入口的配置 |
| `mcause` | **本次**进入处理程序的原因 |
| `mepc` | **本次**处理完后的恢复位置 |

| `mstatus` 字段 | 位置 | 作用 |
|---|---|---|
| `MIE` | bit3 | 当前的中断总开关 |
| `MPIE` | bit7 | 进入处理程序前的总开关状态 |

*/
