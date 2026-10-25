`timescale 1ns/1ps
module tb_soc;
    localparam integer CLOCK_HZ=50000000, BAUD=115200;
    localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
    localparam real CLK_NS=20.0, BIT_NS=CLK_NS*DIV;
    reg clk=0;
    always #(CLK_NS/2) clk=~clk;
    reg rst=1, uart_rx=1;
    wire uart_tx,halted,timer_pending,commit,commit_trap;
    wire [7:0] gpio_out,gpio_oe;
    wire [31:0] trap_pc,trap_cause,trap_tval,pc,insn;
    rv32_soc #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.RESET_MTVEC(32'h7ffc)) dut (
        .clk(clk),.rst(rst),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in(8'ha6),.gpio_out(gpio_out),.gpio_oe(gpio_oe),.timer_pending(timer_pending),
        .halted(halted),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .debug_commit(commit),.debug_trap(commit_trap),.debug_pc(pc),.debug_insn(insn)
    );
    string app,expected,prompt,observed="";
    integer serial_file,trace_file,summary_file;
    integer chars_seen=0,cycles_seen=0,commits_seen=0,data_waits=0,gpio_changes=0;
    integer k,bit_index;
    reg [7:0] serial_byte,previous_gpio;
    reg trap_seen=0;
    reg rx_go=0,prev_iwait=0,prev_dwait=0;
    reg [31:0] prev_ia,rom_first;
    reg [68:0] prev_dp;

    task automatic send_byte(input reg [7:0] value,input real scale);
        integer bitno;
        begin
            #(CLK_NS*2.35); uart_rx=0; #(BIT_NS*scale);
            for (bitno=0;bitno<8;bitno=bitno+1) begin uart_rx=value[bitno]; #(BIT_NS*scale); end
            uart_rx=1; #(BIT_NS*scale);
        end
    endtask

    initial begin
        wait(rx_go);
        if (app == "selftest") send_byte(8'ha5,1.015);
        else if (app == "echo") begin
            send_byte("F",0.99); send_byte("p",1.01);
            send_byte("G",1.0); send_byte("!",0.985);
        end
    end

    initial forever begin
        @(negedge uart_tx);
        if (!rst) begin
            #(BIT_NS*1.5);
            for (bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                serial_byte[bit_index]=uart_tx;
                #(BIT_NS);
            end
            if (uart_tx !== 1'b1) $fatal(1,"TX stop bit invalid");
            if (chars_seen >= expected.len() || serial_byte !== expected[chars_seen])
                $fatal(1,"UART mismatch byte %0d got=%02x expected=%02x text=%s",chars_seen,serial_byte,expected[chars_seen],observed);
            $fwrite(serial_file,"%c",serial_byte);
            observed={observed,serial_byte}; chars_seen=chars_seen+1;
            if (observed == prompt) rx_go=1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            prev_iwait=0; prev_dwait=0; previous_gpio=0;
        end else begin
            cycles_seen=cycles_seen+1;
            if (prev_iwait && (!dut.iv || dut.ia !== prev_ia)) $fatal(1,"SoC instruction bus hold violation");
            if (prev_dwait && (!dut.dv || {dut.dw,dut.da,dut.wd,dut.ws} !== prev_dp)) $fatal(1,"SoC data bus hold violation");
            prev_iwait=dut.iv && !dut.ir; prev_ia=dut.ia;
            prev_dwait=dut.dv && !dut.dr; prev_dp={dut.dw,dut.da,dut.wd,dut.ws};
            if (dut.dv && !dut.dr) data_waits=data_waits+1;
            if (gpio_out !== previous_gpio) begin gpio_changes=gpio_changes+1; previous_gpio=gpio_out; end
            if (commit && !trap_seen) begin
                if(commit_trap) trap_seen=1;
                if (commits_seen < 1024) $fdisplay(trace_file,"%0d,%08x,%08x,%0d",cycles_seen,pc,insn,commit_trap);
                commits_seen=commits_seen+1;
            end
        end
    end

    initial begin
        if (!$value$plusargs("APP=%s",app)) $fatal(1,"APP is required");
        serial_file=$fopen("uart.txt","w"); trace_file=$fopen("boot_trace.csv","w");
        summary_file=$fopen("soc_result.txt","w");
        if (!serial_file || !trace_file || !summary_file) $fatal(1,"Cannot open SoC outputs");
        $fdisplay(trace_file,"cycle,pc,instruction,trap");
        if (app == "selftest") begin
            expected="RV32I SOC BOOT\nMEM PASS\nARITH PASS\nGPIO PASS\nTIMER PASS\nRX?\nRX=A5\nSOC PASS\n";
            prompt="RV32I SOC BOOT\nMEM PASS\nARITH PASS\nGPIO PASS\nTIMER PASS\nRX?\n";
        end else if (app == "echo") begin
            expected="ECHO READY\nFpG!\nECHO PASS\n"; prompt="ECHO READY\n";
        end else if (app == "fault_rom") begin expected=""; prompt="unused"; end
        else $fatal(1,"Unknown app %s",app);
        // Deliberately dirty RAM: startup must copy .data and zero .bss itself.
        #1;
        for (k=0;k<8192;k=k+1) dut.fabric.memory.ram[k]=32'ha5a5a5a5;
        rom_first=dut.fabric.memory.rom[0];
        dut.fabric.memory.rom[8191]=32'h0000006f;
        repeat(10) @(posedge clk);
        @(negedge clk); rst=0;
        while (!trap_seen && cycles_seen < 4000000) begin @(posedge clk); #1; end
        if (!trap_seen) $fatal(1,"SoC timed out app=%s pc=%08x",app,pc);
        repeat(20) begin @(posedge clk); #1; if (dut.dv || commit_trap) $fatal(1,"Side effect or repeated trap in handler loop"); end
        if (dut.fabric.memory.rom[0] !== rom_first) $fatal(1,"ROM was modified");
        if (app == "fault_rom") begin
            if (trap_cause != 7 || trap_tval != 0 || gpio_out != 0) $fatal(1,"ROM protection/precise trap failed");
        end else begin
            if (trap_cause != 11 || dut.cpu.regfile.regs[10] != 0 || dut.cpu.regfile.regs[17] != 93)
                $fatal(1,"Firmware did not exit successfully cause=%0d code=%0d",trap_cause,dut.cpu.regfile.regs[10]);
            if (observed != expected) $fatal(1,"UART transcript incomplete");
            if (gpio_oe != 8'hff || gpio_out !== (app == "selftest" ? 8'h5a : 8'h21)) $fatal(1,"External GPIO outputs wrong");
            if (timer_pending) $fatal(1,"Timer compare not disabled at exit");
        end
        $fdisplay(summary_file,"app=%s cycles=%0d commits=%0d uart_bytes=%0d data_waits=%0d gpio_changes=%0d trap=%0d exit_code=%0d",app,cycles_seen,commits_seen,chars_seen,data_waits,gpio_changes,trap_cause,dut.cpu.regfile.regs[10]);
        $fclose(serial_file); $fclose(trace_file); $fclose(summary_file);
        $display("SOC_PASS app=%s cycles=%0d commits=%0d uart_bytes=%0d",app,cycles_seen,commits_seen,chars_seen);
        $finish;
    end
endmodule
