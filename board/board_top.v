module board_top #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer RESET_HOLD_CYCLES = 250000
) (
    input wire sys_clk,
    input wire key0_n,
    output wire uart_tx,
    output wire led0,
    output wire led1
);
    wire rst_n;
    wire bus_err;
    wire [1:0] gpio_out;
    reg bus_error_seen;

    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk),
        .key0_n(key0_n),
        .rst_n(rst_n)
    );

    soc #(.CLK_FREQ(CLOCK_HZ), .BAUD_RATE(BAUD_RATE)) u_soc (
        .clk(sys_clk),
        .rst_n(rst_n),
        .uart_txd(uart_tx),
        .bus_err(bus_err),
        .gpio_out(gpio_out)
    );

    always @(posedge sys_clk) begin
        if (!rst_n)
            bus_error_seen <= 1'b0;
        else if (bus_err)
            bus_error_seen <= 1'b1;
    end

    assign led0 = rst_n && gpio_out[0];
    assign led1 = rst_n && (gpio_out[1] || bus_error_seen);
endmodule
