module acore_dual_top (
    input sys_clk, key0_n,
    output uart_tx, led0, led1,
    input iic_scl,
    inout iic_sda
);
    board_top #(.ENABLE_DUAL(1)) u_board (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1), .iic_scl(iic_scl), .iic_sda(iic_sda)
    );
endmodule
