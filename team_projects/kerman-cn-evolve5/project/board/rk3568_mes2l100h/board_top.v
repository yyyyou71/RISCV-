`timescale 1ns/1ps
// Logical wrapper for the documented RK3568_MES2L100H board.
// Electrical sign-off is separately required before generating a loadable image.
module board_top #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD = 115200,
    parameter integer M_ENABLE = 1,
    parameter integer BP_ENABLE = 1,
    parameter integer BP_INDEX_BITS = 5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, FETCH_DEPTH=1, FETCH_BYPASS=0, LOAD_FORWARD=0,
    parameter integer DUAL_ENABLE=0, WIDE_FETCH=0, PAIR_BRANCH=0, PAIR_MEMORY=0, PAIR_JALR=0, FAST_MUL=0, FAST_STORE=0, PAIR_MUL=0,
    parameter integer BURST_BACKEND = 1,
    parameter integer BURST_FILL = 1,
    parameter integer MEM_FIRST_WAIT = 0,
    parameter integer MEM_BEAT_GAP = 0,
    parameter integer ICACHE_ENABLE = 1,
    parameter integer DCACHE_ENABLE = 1,
    parameter integer CACHE_SET_BITS = 5,
    parameter integer CACHE_LINE_WORD_BITS = 2,
    parameter integer RESET_HOLD_CYCLES = 250000,
    parameter integer BUTTON_DEBOUNCE_CYCLES = 250000,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire sys_clk, key0_n, key1_n, uart_rx,
    output wire uart_tx, led0, led1
);
    wire soc_reset, key1_pressed, halted;
    wire [7:0] gpio_out, gpio_oe;
    wire soft_reset = gpio_out[7] && gpio_oe[7];
    board_reset #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) u_reset (
        .clk(sys_clk),.key0_n(key0_n),.soft_reset(soft_reset),.reset(soc_reset)
    );
    board_button #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)) u_button (
        .clk(sys_clk),.reset(soc_reset),.key_n(key1_n),.pressed(key1_pressed)
    );
    rv32_soc #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.ROM_FILE(ROM_FILE),.M_ENABLE(M_ENABLE),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.FETCH_DEPTH(FETCH_DEPTH),.FETCH_BYPASS(FETCH_BYPASS),.LOAD_FORWARD(LOAD_FORWARD),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH),
               .PAIR_BRANCH(PAIR_BRANCH),.PAIR_MEMORY(PAIR_MEMORY),.PAIR_JALR(PAIR_JALR),.FAST_MUL(FAST_MUL),.FAST_STORE(FAST_STORE),.PAIR_MUL(PAIR_MUL),.BURST_BACKEND(BURST_BACKEND),.BURST_FILL(BURST_FILL),.MEM_FIRST_WAIT(MEM_FIRST_WAIT),.MEM_BEAT_GAP(MEM_BEAT_GAP),.ICACHE_ENABLE(ICACHE_ENABLE),.DCACHE_ENABLE(DCACHE_ENABLE),.CACHE_SET_BITS(CACHE_SET_BITS),.CACHE_LINE_WORD_BITS(CACHE_LINE_WORD_BITS)) u_soc (
        .clk(sys_clk),.rst(soc_reset),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in({7'b0,key1_pressed}),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .timer_pending(),.halted(halted),.trap_pc(),.trap_cause(),.trap_tval(),
        .debug_commit(),.debug_trap(),.debug_pc(),.debug_insn()
    );
    // LED outputs are active-high per the hardware manual; halt lights both.
    assign led0 = !soc_reset && (halted || (gpio_out[0] && gpio_oe[0]));
    assign led1 = !soc_reset && (halted || (gpio_out[1] && gpio_oe[1]));
endmodule
