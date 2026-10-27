// 面向 RK（瑞芯微）的独立 I2C 从机模块。只有在完成板级评审之后才集成到 SoC 中。
// 本文件不包含 PLL、引脚分配，也不包含 CPU 侧的 MMIO 映射。
module rk_iic_adapter #(
    parameter integer CLK_FREQ_MHZ = 25,
    parameter [6:0] I2C_ADDRESS = 7'h66
)(
    input wire clk,
    input wire rst_n,
    input wire iic_scl,
    inout wire iic_sda,
    // 同时钟域的应用接口：已提交的参数值，以及更新脉冲（仅一个时钟周期）。
    output wire [31:0] param_data,
    output wire param_update,
    // FPGA -> RK 方向的单字节邮箱；后续可扩展为 FIFO。
    input wire [7:0] uplink_data,
    input wire uplink_valid,
    output wire uplink_ready
);
    wire [7:0] reg_addr, reg_wdata, reg_rdata;
    wire reg_write;

    rk_iic_frontend #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
         .I2C_ADDRESS(I2C_ADDRESS)
    ) u_frontend (
        .clk(clk), 
        .rst(!rst_n),
        .scl(iic_scl),
        .sda(iic_sda),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_write(reg_write), 
        .reg_rdata(reg_rdata)
    );

    rk_iic_regs u_regs (
        .clk(clk), 
        .rst_n(rst_n), 
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), 
        .reg_write(reg_write), 
        .reg_rdata(reg_rdata),
        .param_data(param_data), 
        .param_update(param_update),
        .uplink_data(uplink_data), 
        .uplink_valid(uplink_valid),
        .uplink_ready(uplink_ready)
    );
endmodule
