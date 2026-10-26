// Independent RK-facing I2C slave. Integrate into the SoC only after board review.
// No PLL, pin placement or CPU MMIO mapping is included.
module rk_iic_adapter #(
    parameter integer CLK_FREQ_MHZ = 25,
    parameter [6:0] I2C_ADDRESS = 7'h66
)(
    input wire clk,
    input wire rst_n,
    input wire iic_scl,
    inout wire iic_sda,
    // Same-clock application interface: committed parameter and one-cycle pulse.
    output wire [31:0] param_data,
    output wire param_update,
    // One-byte mailbox for FPGA -> RK; later extend with a FIFO.
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
