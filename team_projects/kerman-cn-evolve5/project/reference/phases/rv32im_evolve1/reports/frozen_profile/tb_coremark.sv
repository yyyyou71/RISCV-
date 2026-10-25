`timescale 1ns/1ps
module tb_coremark;
    localparam real BIT_NS=8680.0; // 25 MHz / 217 clocks per bit
    reg clk=0;
    always #20 clk=~clk;
    reg rx=1;
    wire tx,led0,led1;
    board_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.uart_rx(rx),.uart_tx(tx),.led0(led0),.led1(led1));
    string line="";
    string results[0:15];
    integer ready_count=0,result_count=0,cycles=0,fd,metrics,bitno,k;
    integer expected_ready;
    reg [7:0] ch;
    reg [63:0] timer_start,measured_cycles[0:15];
    reg [63:0] start_samples[0:15],stop_samples[0:15],first_command_tick,first_latency;
    integer timer_reads=0;
    reg in_run=0;
    reg port_check=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(dut.halted) $fatal(1,"CoreMark CPU halted pc=%08x cause=%0d",dut.u_soc.cpu.trap_pc,dut.u_soc.cpu.trap_cause);
        if(!dut.soc_reset && dut.u_soc.fabric.pv && !dut.u_soc.fabric.pw && dut.u_soc.fabric.p_ready && dut.u_soc.fabric.pa==32'h40002000) begin
            if(!led0) $fatal(1,"Busy LED is not asserted during benchmark timer sampling");
            if((timer_reads%2)==0) begin
                timer_start=dut.u_soc.fabric.timer.count;
                start_samples[timer_reads/2]=timer_start;
                if(timer_reads==0) first_latency=timer_start-first_command_tick;
            end
            else begin
                stop_samples[timer_reads/2]=dut.u_soc.fabric.timer.count;
                measured_cycles[timer_reads/2]=dut.u_soc.fabric.timer.count-timer_start;
                $fdisplay(metrics,"%0d,%0d",timer_reads/2,measured_cycles[timer_reads/2]);
            end
            timer_reads=timer_reads+1;
        end
    end
    initial forever begin
        @(negedge tx);
        if(!dut.soc_reset) begin
            #(BIT_NS*1.5);
            for(bitno=0;bitno<8;bitno=bitno+1) begin ch[bitno]=tx; #(BIT_NS); end
            if(tx!==1) $fatal(1,"UART stop-bit failure");
            $fwrite(fd,"%c",ch);
            if(ch==10) begin
                if(line=="CM_READY") ready_count=ready_count+1;
                if(line=="PORT_CHECK PASS") port_check=1;
                if(line.len()>=10 && line.substr(0,9)=="CM_RESULT ") begin
                    results[result_count]=line; result_count=result_count+1;
                    $display("%s",line);
                end
                if(line=="CM_FAIL: CRC/data mismatch" || line=="PORT_CHECK FAIL" || line=="CM_COMMAND_ERROR")
                    $fatal(1,"Firmware failure: %s",line);
                line="";
            end else line={line,ch};
        end
    end
    task automatic send_string(input string text);
        integer a,b;
        begin
            for(a=0;a<text.len();a=a+1) begin
                #53; rx=0; #(BIT_NS);
                for(b=0;b<8;b=b+1) begin rx=(text[a]>>b)&1; #(BIT_NS); end
                rx=1; #(BIT_NS);
            end
        end
    endtask
    task automatic wait_ready(input integer n);
        integer count;
        begin
            count=0;
            // A slower configured memory makes a correct uncached run longer.
            // This changes only the test watchdog, never timer ticks or CRC rules.
            while(ready_count<n && count<(15000000+2500000*dut.MEM_FIRST_WAIT)) begin @(posedge clk); count=count+1; end
            if(ready_count<n) $fatal(1,"CoreMark command timed out at PC=%08x",dut.u_soc.cpu.retire_pc);
        end
    endtask
    initial begin
        fd=$fopen("coremark_uart.txt","w"); metrics=$fopen("timer_intervals.csv","w");
        $fdisplay(metrics,"run,cycles");
        #1; for(k=0;k<8192;k=k+1) dut.u_soc.fabric.memory.ram[k]=32'ha5a5a5a5;
        wait_ready(1);
        if(!port_check) $fatal(1,"Port integer timing helper self-check missing");
        first_command_tick=dut.u_soc.fabric.timer.count;
        send_string("q\n"); wait_ready(2);
        send_string("w\n"); wait_ready(3);
        // Set up a low-word wrap while idle. The timer runs normally throughout
        // the measured interval: no acceleration, pausing or fabricated duration.
        @(negedge clk);
        dut.u_soc.fabric.timer.count=64'h0000000100000000-(first_latency+measured_cycles[0]/2);
        send_string("p 8\n"); wait_ready(4);
        if(start_samples[2][63:32]!=0 || stop_samples[2][63:32]!=1)
            $fatal(1,"Timer rollover case did not span the low-word boundary");
        $display("COREMARK_TIMER_ROLLOVER_PASS");
        send_string("v 8\n"); wait_ready(5);
        if(result_count!=4 || timer_reads!=8) $fatal(1,"Missing result/timer intervals %0d/%0d",result_count,timer_reads);
        if(led0 || led1) $fatal(1,"Short checks must not leave valid-score indication on");
        $fclose(fd); $fclose(metrics);
        $display("COREMARK_SIM_PASS runs=%0d cycles=%0d",result_count,cycles);
        $display("CACHE_ACTIVITY ih=%0d im=%0d dh=%0d dm=%0d wh=%0d wm=%0d",dut.u_soc.i_cache.read_hits,dut.u_soc.i_cache.read_misses,
                 dut.u_soc.d_cache.read_hits,dut.u_soc.d_cache.read_misses,dut.u_soc.d_cache.write_hits,dut.u_soc.d_cache.write_misses);
        $finish;
    end
    initial begin #(64'd5000000000+64'd1000000000*dut.MEM_FIRST_WAIT); $fatal(1,"CoreMark simulation global timeout"); end
    front_profile_monitor front_statistics();
    dual_profile_monitor dual_statistics();
    evolve_profile_monitor detailed_statistics();
    bp_profile_monitor branch_statistics();
    burst_profile_monitor bus_statistics();
endmodule
