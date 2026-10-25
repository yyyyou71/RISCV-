`timescale 1ns/1ps
module tb_board;
    localparam integer DIV=217;
    localparam real BIT_NS=DIV*40.0;
    reg sys_clk=0;
    always #20 sys_clk=~sys_clk;
    reg key0_n=1,key1_n=1,uart_rx=1;
    wire uart_tx,led0,led1;
    board_top dut(.sys_clk(sys_clk),.key0_n(key0_n),.key1_n(key1_n),.uart_rx(uart_rx),.uart_tx(uart_tx),.led0(led0),.led1(led1));
    string lines[0:127];
    string current_line="";
    integer line_count=0,next_line=0,checks=0,cycles=0,resets=0;
    integer serial_fd,summary_fd,bitno,k,guard;
    reg [7:0] received;
    reg good;
    reg old_reset=1;
    reg [63:0] before_tick,after_tick;
    always @(posedge sys_clk) begin
        cycles=cycles+1;
        if (dut.soc_reset && !old_reset) resets=resets+1;
        old_reset=dut.soc_reset;
        if (dut.halted) $fatal(1,"Unexpected CPU halt in persistent board demo");
    end
    initial forever begin
        @(negedge uart_tx);
        if (!dut.soc_reset) begin
            good=1;
            #(BIT_NS*1.5);
            for(bitno=0;bitno<8;bitno=bitno+1) begin
                if (dut.soc_reset) good=0;
                received[bitno]=uart_tx;
                #(BIT_NS);
            end
            if (dut.soc_reset) good=0;
            if (good) begin
                if (uart_tx !== 1) $fatal(1,"Board UART stop bit invalid");
                $fwrite(serial_fd,"%c",received);
                if (received==10) begin
                    lines[line_count]=current_line;
                    line_count=line_count+1;
                    $display("BOARD_UART %s",current_line);
                    current_line="";
                end else current_line={current_line,received};
            end else current_line="";
        end
    end
    task automatic expect_line(input string wanted);
        integer timeout;
        begin
            timeout=0;
            while(line_count<=next_line && timeout<2000000) begin
                @(posedge sys_clk); timeout=timeout+1;
            end
            if(line_count<=next_line) $fatal(1,"Timed out waiting for: %s",wanted);
            if(lines[next_line]!=wanted) $fatal(1,"Line mismatch actual=%s expected=%s",lines[next_line],wanted);
            next_line=next_line+1;
        end
    endtask
    task automatic boot_banner;
        begin
            expect_line("RV32I BOARD READY");
            expect_line("CLK=25000000 BAUD=115200");
            expect_line("BOOTCHECK PASS");
            expect_line("h=help s=status t=toggle r=reset");
            if(dut.u_soc.fabric.uart.divisor!=217) $fatal(1,"25MHz UART divider wrong");
            if(dut.gpio_oe!==8'h83 || led1!==0) $fatal(1,"Boot GPIO/BSS state wrong");
        end
    endtask
    task automatic command(input reg [7:0] c);
        integer n;
        begin
            #53; uart_rx=0; #(BIT_NS);
            for(n=0;n<8;n=n+1) begin uart_rx=c[n]; #(BIT_NS); end
            uart_rx=1; #(BIT_NS);
        end
    endtask
    task automatic passed(input string name);
        begin checks=checks+1; $display("BOARD_CHECK %s",name); end
    endtask
    initial begin
        serial_fd=$fopen("board_uart.txt","w"); summary_fd=$fopen("board_result.txt","w");
        if(!serial_fd || !summary_fd) $fatal(1,"Cannot open board output files");
        #1;
        for(k=0;k<8192;k=k+1) dut.u_soc.fabric.memory.ram[k]=32'ha5a5a5a5;
        if(dut.soc_reset!==1) $fatal(1,"Power-on reset was not asserted");
        boot_banner(); passed("power_on_and_dirty_ram_boot");
        before_tick=dut.u_soc.fabric.timer.count;
        guard=0;
        while(!led0 && guard<13000000) begin @(posedge sys_clk); #1; guard=guard+1; end
        after_tick=dut.u_soc.fabric.timer.count;
        if(!led0 || after_tick-before_tick<12490000 || after_tick-before_tick>12510000)
            $fatal(1,"500ms physical heartbeat period wrong delta=%0d",after_tick-before_tick);
        passed("real_500ms_heartbeat");
        command("s"); expect_line("KEY1=0 LED1=0"); passed("uart_status");
        for(k=0;k<4;k=k+1) begin
            @(negedge sys_clk); key1_n=0; repeat(20) @(posedge sys_clk);
            @(negedge sys_clk); key1_n=1; repeat(20) @(posedge sys_clk);
        end
        if(led1 || line_count!=next_line) $fatal(1,"Short key bounce passed filter");
        passed("key1_bounce_rejected");
        @(negedge sys_clk); key1_n=0;
        expect_line("KEY1=1"); if(!led1) $fatal(1,"Pressed key not reflected on LED1");
        repeat(260000) @(posedge sys_clk);
        if(line_count!=next_line) $fatal(1,"Held key emitted repeated transitions");
        @(negedge sys_clk); key1_n=1;
        expect_line("KEY1=0"); if(led1) $fatal(1,"Released key not reflected on LED1");
        passed("key1_press_hold_release");
        command("t"); expect_line("KEY1=0 LED1=1"); if(!led1) $fatal(1,"UART toggle failed");
        passed("uart_toggle");
        command("h"); expect_line("h=help s=status t=toggle r=reset");
        command("x"); expect_line("UNKNOWN"); passed("uart_help_and_unknown");
        command("r"); expect_line("RESET"); boot_banner();
        if(resets!=1) $fatal(1,"Software reset count wrong %0d",resets);
        passed("uart_reset_and_bss_reinitialization");
        @(negedge sys_clk); key0_n=0; #1;
        if(!dut.soc_reset) $fatal(1,"KEY0 did not assert reset asynchronously");
        repeat(10) @(posedge sys_clk);
        @(negedge sys_clk); key0_n=1; repeat(20) @(posedge sys_clk);
        @(negedge sys_clk); key0_n=0; repeat(10) @(posedge sys_clk);
        @(negedge sys_clk); key0_n=1;
        repeat(1000) @(posedge sys_clk);
        if(!dut.soc_reset) $fatal(1,"Reset released before debounce hold elapsed");
        boot_banner(); passed("key0_reset_bounce_and_release_hold");
        if(line_count!=next_line || resets!=2) $fatal(1,"Unexpected output/reset count");
        $fdisplay(summary_fd,"checks=%0d cycles=%0d complete_lines=%0d resets=%0d",checks,cycles,line_count,resets);
        $fclose(serial_fd); $fclose(summary_fd);
        $display("BOARD_SIM_PASS checks=%0d cycles=%0d resets=%0d",checks,cycles,resets);
        $finish;
    end
    initial begin #1200000000; $fatal(1,"Board simulation global timeout"); end
endmodule
