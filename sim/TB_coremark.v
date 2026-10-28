`timescale 1ns/1ps
module TB_coremark #(
    parameter integer MAX_CYCLES = 600000000
);
`ifdef PANGO_IP
    GTP_GRS GRS_INST (.GRS_N(1'b1));
`endif
    localparam integer BIT_NS = 40 * (25000000 / 115200);
    reg sys_clk = 0;
    reg key0_n = 1;
    wire uart_tx;
    wire led0;
    wire led1;
    integer cycles = 0;
    integer bit_index;
    integer characters = 0;
    reg [7:0] received_byte;
    always #20 sys_clk = ~sys_clk;

    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );

    always begin
        @(negedge uart_tx);
        #(BIT_NS / 2);
        if (uart_tx !== 0)
            $fatal(1, "UART start bit failed");
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            #(BIT_NS);
            received_byte[bit_index] = uart_tx;
        end
        #(BIT_NS);
        if (uart_tx !== 1)
            $fatal(1, "UART stop bit failed");
        characters = characters + 1;
        $write("%c", received_byte);
    end

    always @(posedge sys_clk) begin
        cycles <= cycles + 1;
        if (cycles >= MAX_CYCLES)
            $fatal(1, "CoreMark board simulation timed out");
        if (dut.rst_n && (dut.bus_err || led1))
            $fatal(1, "Unexpected bus error");
        if (dut.rst_n && dut.u_soc.dev_we && dut.u_soc.dev_addr_wr == 32'h00030000) begin
            if (dut.u_soc.dev_wdata !== 0 || led0 !== 1 || characters < 100)
                $fatal(1, "CoreMark exit/LED/UART failed");
            $display("PASS: CoreMark board exit_code=0; %0d UART characters; %0d cycles", characters, cycles);
            $finish;
        end
    end
endmodule
