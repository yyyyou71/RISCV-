`timescale 1ns/1ps
module TB_evolve5_control;
    reg clk = 0;
    reg key0_n = 1;
    wire uart_tx, led0, led1;
    integer cycles = 0;
    integer pairs = 0;
    integer interrupts = 0;
    integer exceptions = 0;
    integer word_index;
    always #20 clk = ~clk;
    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(clk), .key0_n(key0_n), .uart_tx(uart_tx), .led0(led0), .led1(led1)
    );
    initial begin
        #1;
        for (word_index=0; word_index<8192; word_index=word_index+1) begin
            dut.u_soc.fabric.memory.rom.storage[word_index] = 32'h00000013;
            dut.u_soc.fabric.memory.ram.storage[word_index] = 0;
        end
        $readmemh("build/evolve5-control/control.hex", dut.u_soc.fabric.memory.rom.storage);
    end
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (dut.u_soc.cpu.retire2_valid) pairs <= pairs + 1;
        if (dut.u_soc.cpu.interrupt_taken) interrupts <= interrupts + 1;
        if (dut.u_soc.cpu.retire_trap) exceptions <= exceptions + 1;
        if (dut.u_soc.gpio_out == 2) $fatal(1, "EVOLVE5 control firmware reported failure");
        if (dut.u_soc.gpio_out == 1) begin
            if (pairs == 0 || interrupts != 1 || exceptions != 1 ||
                dut.u_soc.cpu.regfile.regs[22] !== 2 || dut.u_soc.cpu.regfile.regs[23] !== 1)
                $fatal(1, "Missing dual retirement, illegal DIV trap, timer IRQ or MRET");
            $display("PASS: EVOLVE5 control, RAW/WAW, multiply, memory, illegal DIV, timer IRQ/MRET; pairs=%0d cycles=%0d", pairs, cycles);
            $finish;
        end
        if (cycles > 200000) $fatal(1, "EVOLVE5 control timeout");
    end
endmodule
