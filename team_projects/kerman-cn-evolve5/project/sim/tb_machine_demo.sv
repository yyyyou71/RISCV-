`timescale 1ns/1ps
module tb_machine_demo;
    reg clk=0; always #20 clk=~clk;
    wire tx,led0,led1;
    board_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.uart_rx(1'b1),.uart_tx(tx),.led0(led0),.led1(led1));
    integer serial_fd,trace_fd,k,r,bitno,depth=0,max_depth=0,exceptions=0,interrupts=0,returns=0,ticks=0,pass_lines=0;
    reg [31:0] saved_regs[0:7][0:31];
    reg [7:0] byte_value;
    string line="";
    reg nested_pass=0,ready=0,iwait=0,dwait=0,cache_pass=0,hardware_id=0;
    reg [31:0] previous_ia;
    reg [68:0] previous_dp;
    always @(posedge clk) if(!dut.soc_reset) begin
        if(iwait && (!dut.u_soc.iv || dut.u_soc.ia!==previous_ia)) $fatal(1,"Instruction bus changed across firmware trap");
        if(dwait && (!dut.u_soc.dv || {dut.u_soc.dw,dut.u_soc.da,dut.u_soc.wd,dut.u_soc.ws}!==previous_dp)) $fatal(1,"Data bus changed across firmware trap");
        iwait=dut.u_soc.iv&&!dut.u_soc.ir; previous_ia=dut.u_soc.ia;
        dwait=dut.u_soc.dv&&!dut.u_soc.dr; previous_dp={dut.u_soc.dw,dut.u_soc.da,dut.u_soc.wd,dut.u_soc.ws};
        if(dut.u_soc.cpu.retire_trap || dut.u_soc.cpu.interrupt_taken) begin
            if(depth>=8) $fatal(1,"Runaway nested trap");
            for(r=0;r<32;r=r+1) saved_regs[depth][r]=dut.u_soc.cpu.regfile.regs[r];
            depth=depth+1; if(depth>max_depth) max_depth=depth;
            if(dut.u_soc.cpu.interrupt_taken) interrupts=interrupts+1; else exceptions=exceptions+1;
            $fdisplay(trace_fd,"enter,%0d,%0d,%08x,%08x",depth,dut.u_soc.cpu.interrupt_taken,dut.u_soc.cpu.retire_pc,dut.u_soc.cpu.retire_cause);
        end
        if(dut.u_soc.cpu.retire_valid && !dut.u_soc.cpu.retire_trap && dut.u_soc.cpu.retire_insn==32'h30200073) begin
            if(depth==0) $fatal(1,"MRET without a matching software trap frame");
            depth=depth-1;
            for(r=1;r<32;r=r+1) if(dut.u_soc.cpu.regfile.regs[r]!==saved_regs[depth][r])
                $fatal(1,"Trap frame corrupted x%0d got=%08x expected=%08x",r,dut.u_soc.cpu.regfile.regs[r],saved_regs[depth][r]);
            returns=returns+1; $fdisplay(trace_fd,"return,%0d,0,%08x,00000000",depth,dut.u_soc.cpu.retire_next_pc);
        end
    end
    initial forever begin
        @(negedge tx);
        if(!dut.soc_reset) begin
            #(8680*1.5);
            for(bitno=0;bitno<8;bitno=bitno+1) begin byte_value[bitno]=tx; #8680; end
            if(tx!==1) $fatal(1,"Bad UART stop bit");
            $fwrite(serial_fd,"%c",byte_value);
            if(byte_value==10) begin
                if(line.len()>=10 && line.substr(0,9)=="TRAP_PASS ") pass_lines=pass_lines+1;
                if(line=="NESTED_TRAP_PASS") nested_pass=1;
                if(line.len()>=19 && line.substr(0,18)=="CACHE_SELFTEST_PASS") cache_pass=1;
                if(line.len()>=30 && line.substr(0,29)=="HW_ID=43414333 HW_CFG=0000001F") hardware_id=1;
                if(line.len()>=19 && line.substr(0,18)=="CACHE_SELFTEST_FAIL") $fatal(1,"Cache selftest failure %s",line);
                if(line.len()>=13 && line.substr(0,12)=="MACHINE_READY") ready=1;
                if(line.len()>=13 && line.substr(0,12)=="MACHINE_FATAL") $fatal(1,"Firmware reported %s",line);
                k=$sscanf(line,"IRQ_TICK=%d",ticks);
                $display("UART %s",line); line="";
            end else line={line,byte_value};
        end
    end
    initial begin
        serial_fd=$fopen("machine_uart.txt","w"); trace_fd=$fopen("trap_frames.csv","w");
        $fdisplay(trace_fd,"event,depth,interrupt,pc,cause");
        #1; for(k=0;k<8192;k=k+1) dut.u_soc.fabric.memory.ram[k]=32'ha5a5a5a5;
        wait(ticks>=4); #100;
        if(!ready || !nested_pass || !cache_pass || !hardware_id || pass_lines!=11 || exceptions!=13 || interrupts!=4 || returns!=17 || depth!=0 || max_depth!=2)
            $fatal(1,"Demo result mismatch pass=%0d exceptions=%0d interrupts=%0d returns=%0d depth=%0d maxdepth=%0d",pass_lines,exceptions,interrupts,returns,depth,max_depth);
        if(!led1) $fatal(1,"Self-test pass LED absent");
        $fclose(serial_fd); $fclose(trace_fd);
        $display("MACHINE_DEMO_PASS exceptions=13 interrupts=4 frame_returns=17 all_31_registers_preserved=1 nested_depth=2");
        $finish;
    end
    initial begin #(64'd5000000000); $fatal(1,"Machine demo timeout"); end
endmodule
