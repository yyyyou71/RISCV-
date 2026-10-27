`timescale 1ns/1ps

module TB_board;
`ifdef PANGO_IP
    GTP_GRS GRS_INST (.GRS_N(1'b1));
`endif
    localparam integer CLOCK_HZ = 25000000;
    localparam integer BAUD_RATE = 115200;
    localparam integer BIT_NS = 40 * (CLOCK_HZ / BAUD_RATE);
    reg sys_clk = 1'b0;
    reg key0_n = 1'b1;
    wire uart_tx;
    wire led0;
    wire led1;
    tri1 iic_sda;
    reg [7:0] received_byte;
    integer bit_index;
    integer character_count = 0;
    integer completed_runs = 0;
    // Explicit CR/LF bytes keep the expected transcript portable across simulators.
    string expected = {"RV32I FPGA 25MHz 115200", 8'h0d, 8'h0a,
                       "RAM INIT/BSS/BYTE/HALF/WORD PASS", 8'h0d, 8'h0a,
                       "SELFTEST PASS", 8'h0d, 8'h0a};

    always #20 sys_clk = ~sys_clk;

    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(sys_clk),
        .key0_n(key0_n),
        .uart_tx(uart_tx),
        .led0(led0),
        .led1(led1),
        .iic_scl(1'b1),
        .iic_sda(iic_sda)
    );

    always begin
        @(negedge uart_tx);
        #(BIT_NS / 2);
        if (uart_tx !== 1'b0)
            $fatal(1, "UART start bit failed");
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            #(BIT_NS);
            received_byte[bit_index] = uart_tx;
        end
        #(BIT_NS);
        if (uart_tx !== 1'b1)
            $fatal(1, "UART stop bit failed");
        if (character_count >= expected.len() || received_byte !== expected[character_count])
            $fatal(1, "UART byte %0d: got %h", character_count, received_byte);
        character_count = character_count + 1;
        $write("%c", received_byte);
    end

    always @(posedge sys_clk) begin
        if (dut.rst_n && dut.bus_err)
            $fatal(1, "Unmapped CPU access");
        if (dut.rst_n && dut.u_soc.dev_we && dut.u_soc.dev_addr_wr == 32'h00030000) begin
            if (dut.u_soc.dev_wdata !== 32'd1 || character_count != expected.len())
                $fatal(1, "Selftest exit or UART transcript failed");
            if (led0 !== 1'b1 || led1 !== 1'b0)
                $fatal(1, "Board status LEDs failed");
            completed_runs = completed_runs + 1;
        end
    end

    initial begin
        wait(completed_runs == 1);
        @(negedge sys_clk);
        #7 key0_n = 1'b0;
        repeat (5) @(negedge sys_clk);
        character_count = 0;
        key0_n = 1'b1;
        wait(completed_runs == 2);
        $display("PASS: board boot, UART 115200, RAM, GPIO, timer and button restart at 25 MHz");
        $finish;
    end

    initial begin
        #40000000;
        $fatal(1, "Board selftest timed out");
    end
endmodule
