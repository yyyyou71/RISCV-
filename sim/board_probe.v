module board_probe (
    input wire sys_clk,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1,
    output wire dev_we,
    output wire [31:0] dev_addr,
    output wire [31:0] dev_data,
    output wire bus_error
);
    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );
    assign dev_we = dut.rst_n && dut.u_soc.dev_we;
    assign dev_addr = dut.u_soc.dev_addr_wr;
    assign dev_data = dut.u_soc.dev_wdata;
    assign bus_error = dut.rst_n && dut.bus_err;
endmodule
