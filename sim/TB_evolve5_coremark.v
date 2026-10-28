`timescale 1ns/1ps
module TB_evolve5_coremark;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    localparam integer BIT_NS = 40 * (25000000 / 115200);
    reg sys_clk = 0;
    reg key0_n = 1;
    wire uart_tx, led0, led1;
    integer cycles = 0;
    integer characters = 0;
    integer bit_index;
    integer first_retired = 0;
    integer second_retired = 0;
    integer samples = 0;
    integer start_cycle = 0;
    integer start_retired = 0;
    integer start_second = 0;
    integer measured_cycles = 0;
    integer measured_retired = 0;
    integer measured_second = 0;
    reg [7:0] received;
    always #20 sys_clk = ~sys_clk;
    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );
    always begin
        @(negedge uart_tx);
        #(BIT_NS/2);
        if (uart_tx !== 0) $fatal(1, "UART start failed");
        for (bit_index=0; bit_index<8; bit_index=bit_index+1) begin
            #(BIT_NS);
            received[bit_index] = uart_tx;
        end
        #(BIT_NS);
        if (uart_tx !== 1) $fatal(1, "UART stop failed");
        characters = characters + 1;
        $write("%c", received);
    end
    always @(posedge sys_clk) begin
        if (dut.u_soc.fabric.pv && !dut.u_soc.fabric.pw && dut.u_soc.fabric.pa == 32'h40002000 && dut.u_soc.fabric.p_ready) begin
            if (samples == 0) begin
                start_cycle = cycles;
                start_retired = first_retired + second_retired;
                start_second = second_retired;
            end else if (samples == 1) begin
                measured_cycles = cycles - start_cycle;
                measured_retired = first_retired + second_retired - start_retired;
                measured_second = second_retired - start_second;
            end
            samples = samples + 1;
        end
        cycles <= cycles + 1;
        if (dut.u_soc.cpu.retire_valid && !dut.u_soc.cpu.retire_trap)
            first_retired <= first_retired + 1;
        if (dut.u_soc.cpu.retire2_valid) second_retired <= second_retired + 1;
        if (cycles > 600000000 || led1) $fatal(1, "EVOLVE5 timeout/trap");
        if (led0) begin
            if (characters < 100 || second_retired == 0) $fatal(1, "No UART report or dual retirement");
            $display("PASS: CoreMark board exit_code=0; %0d UART characters; %0d cycles", characters, cycles);
            $display("DUAL RETIRED: %0d first, %0d second", first_retired, second_retired);
            $display("BENCH COUNTERS: cycles=%0d retired=%0d second=%0d", measured_cycles, measured_retired, measured_second);
            $finish;
        end
    end
endmodule
