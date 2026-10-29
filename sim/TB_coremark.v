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
    integer counter_samples = 0;
    integer start_cycle = 0;
    integer measured_cycles = 0;
    reg [63:0] start_retired = 0, start_second = 0, measured_retired = 0, measured_second = 0;
    always #20 sys_clk = ~sys_clk;

    board_top #(.RESET_HOLD_CYCLES(8)
`ifdef ACORE_DUAL
        , .ENABLE_DUAL(1)
`endif
    ) dut (
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
`ifdef ACORE_DUAL
        if (dut.rst_n && dut.u_soc.dev_re && dut.u_soc.dev_addr_rd == 32'h3000c) begin
            if (counter_samples == 0) begin
                start_cycle = cycles;
                start_retired = dut.u_soc.u_core.retired_count;
                start_second = dut.u_soc.u_core.secondary_count;
            end else if (counter_samples == 1) begin
                measured_cycles = cycles - start_cycle;
                measured_retired = dut.u_soc.u_core.retired_count - start_retired;
                measured_second = dut.u_soc.u_core.secondary_count - start_second;
            end
            counter_samples = counter_samples + 1;
        end
`endif
        if (cycles >= MAX_CYCLES)
            $fatal(1, "CoreMark board simulation timed out");
        if (dut.rst_n && (dut.bus_err || led1))
            $fatal(1, "Unexpected bus error");
        if (dut.rst_n && dut.u_soc.dev_we && dut.u_soc.dev_addr_wr == 32'h00030000) begin
            if (dut.u_soc.dev_wdata !== 0 || led0 !== 1 || characters < 100)
                $fatal(1, "CoreMark exit/LED/UART failed");
            $display("PASS: CoreMark board exit_code=0; %0d UART characters; %0d cycles", characters, cycles);
`ifdef ACORE_DUAL
            if (counter_samples != 2 || measured_second == 0) $fatal(1, "No dual issue in measured interval");
            $display("BENCH COUNTERS: cycles=%0d retired=%0d second=%0d", measured_cycles, measured_retired, measured_second);
`endif
            $finish;
        end
    end
endmodule
