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
    output wire retire_first,
    output wire retire_second,
    output wire cycle_sample
);
    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );
    assign dev_we = led0;
    assign dev_addr = 32'h00030000;
    assign dev_data = 0;
    assign bus_error = led1;
    assign retire_first = dut.u_soc.cpu.retire_valid && !dut.u_soc.cpu.retire_trap;
    assign retire_second = dut.u_soc.cpu.retire2_valid;
    assign cycle_sample = dut.u_soc.fabric.pv && !dut.u_soc.fabric.pw &&
                          dut.u_soc.fabric.pa == 32'h40002000 && dut.u_soc.fabric.p_ready;
endmodule
