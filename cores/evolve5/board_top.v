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
    wire halted;
    wire debug_trap;
    wire [7:0] gpio_out;
    reg trap_seen;
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk), .key0_n(key0_n), .rst_n(rst_n)
    );
    rv32_soc #(
        .CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD_RATE), .M_ENABLE(1),
        .BP_INDEX_BITS(5), .FETCH_DEPTH(4), .FETCH_BYPASS(1), .LOAD_FORWARD(1),
        .DUAL_ENABLE(1), .WIDE_FETCH(1), .PAIR_BRANCH(1), .PAIR_MEMORY(1),
        .PAIR_JALR(1), .FAST_STORE(1), .FAST_MUL(1), .PAIR_MUL(1),
        .ICACHE_ENABLE(1), .DCACHE_ENABLE(1), .CACHE_SET_BITS(5),
        .CACHE_LINE_WORD_BITS(2), .BURST_BACKEND(1), .BURST_FILL(1)
    ) u_soc (
        .clk(sys_clk), .rst(!rst_n), .uart_rx(1'b1), .uart_tx(uart_tx),
        .gpio_in(8'b0), .gpio_out(gpio_out), .gpio_oe(), .timer_pending(),
        .halted(halted), .trap_pc(), .trap_cause(), .trap_tval(),
        .debug_commit(), .debug_trap(debug_trap), .debug_pc(), .debug_insn()
    );
    always @(posedge sys_clk) begin
        if (!rst_n)
            trap_seen <= 0;
        else if (debug_trap || halted)
            trap_seen <= 1;
    end
    assign led0 = rst_n && gpio_out[0];
    assign led1 = rst_n && (gpio_out[1] || trap_seen);
endmodule
