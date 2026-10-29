module board_probe (
    input wire sys_clk,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1,
    output wire dev_we,
    output wire [31:0] dev_addr,
    output wire [31:0] dev_data,
    output wire bus_error,
    output wire cycle_sample,
    output wire retire_first,
    output wire retire_second
);
    board_top #(.RESET_HOLD_CYCLES(8)
`ifdef ACORE_DUAL
        , .ENABLE_DUAL(1)
`endif
    ) dut (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );
    assign dev_we = dut.rst_n && dut.u_soc.dev_we;
    assign dev_addr = dut.u_soc.dev_addr_wr;
    assign dev_data = dut.u_soc.dev_wdata;
    assign bus_error = dut.rst_n && dut.bus_err;
    assign cycle_sample = dut.rst_n && dut.u_soc.dev_re && dut.u_soc.dev_addr_rd == 32'h3000c;
    assign retire_first = dut.rst_n && dut.u_soc.u_core.retire_a_MEM;
    assign retire_second = dut.rst_n && dut.u_soc.u_core.b_valid_MEM;
endmodule
