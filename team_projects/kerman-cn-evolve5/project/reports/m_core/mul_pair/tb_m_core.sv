`timescale 1ns/1ps
module tb_core;
    localparam MEM_BYTES = 65536;
    localparam FAULT_BASE = 32'h0000f000;
    localparam MAX_TRACE = 100000;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    wire iv, ir, ie, dv, dw, dr, de;
    wire [31:0] ia, idata, da, wd, rdata;
    wire [3:0] ws;
    wire halted, tv, tt, tw;
    wire [31:0] tpc, tinsn, tnpc, trddata, taddr, tdata, trdata, tcause, tval;
    wire [4:0] trd;
    wire [3:0] tmask, trmask;
    wire [31:0] halt_pc, halt_cause, halt_tval;
    wire [63:0] cycles, retired, load_stalls, dwaits, iwaits, redirects;
    wire tv2,tw2;
    wire [31:0] tpc2,tinsn2,tnpc2,trddata2,idata_second,taddr2,tdata2,trdata2;
    wire [3:0] tmask2,trmask2;
    wire [4:0] trd2;
    wire [447:0] packet2={tpc2,tinsn2,tnpc2,{31'b0,tw2},{27'b0,trd2},trddata2,
                         taddr2,{28'b0,tmask2},tdata2,{28'b0,trmask2},trdata2,32'b0,32'b0,32'b0};
    integer pair_packets=0;
    rv32_core #(.M_ENABLE(1),.BP_INDEX_BITS(5),.GSHARE_ENABLE(0),.PHT_BITS(8),.RAS_DEPTH(0),.FETCH_DEPTH(4),.FETCH_BYPASS(1),.LOAD_FORWARD(1),.DUAL_ENABLE(1),.WIDE_FETCH(1),.PAIR_BRANCH(1),.PAIR_MEMORY(1),.PAIR_JALR(1),.FAST_STORE(1),.FAST_MUL(1),.PAIR_MUL(1),.RESET_MTVEC(32'he000)) dut (
        .clk(clk), .rst(rst), .irq_timer(1'b0), .interrupt_taken(),
        .imem_valid(iv), .imem_addr(ia), .imem_ready(ir), .imem_rdata(idata), .imem_error(ie),.imem_second_valid(1'b1 && ia[3:2]!=3),.imem_second_error(ia+4>=FAULT_BASE),.imem_rdata_second(idata_second),
        .dmem_valid(dv), .dmem_write(dw), .dmem_addr(da), .dmem_wdata(wd), .dmem_wstrb(ws),
        .dmem_ready(dr), .dmem_rdata(rdata), .dmem_error(de),
        .halted(halted), .trap_pc(halt_pc), .trap_cause(halt_cause), .trap_tval(halt_tval),
        .retire2_mem_addr(taddr2),.retire2_mem_wmask(tmask2),.retire2_mem_rmask(trmask2),.retire2_mem_wdata(tdata2),.retire2_mem_rdata(trdata2),.retire2_valid(tv2),.retire2_rd_we(tw2),.retire2_pc(tpc2),.retire2_insn(tinsn2),.retire2_next_pc(tnpc2),.retire2_rd(trd2),.retire2_rd_data(trddata2),.retire_valid(tv), .retire_trap(tt), .retire_rd_we(tw),
        .retire_pc(tpc), .retire_insn(tinsn), .retire_next_pc(tnpc),
        .retire_rd(trd), .retire_rd_data(trddata),
        .retire_mem_addr(taddr), .retire_mem_wdata(tdata), .retire_mem_wmask(tmask),
        .retire_mem_rdata(trdata), .retire_mem_rmask(trmask), .retire_cause(tcause), .retire_tval(tval),
        .cycles(cycles), .instret(retired), .load_stall_cycles(load_stalls),
        .data_wait_cycles(dwaits), .fetch_wait_cycles(iwaits), .redirect_count(redirects)
    );

    reg [7:0] mem [0:MEM_BYTES-1];
    reg [7:0] expected_mem [0:MEM_BYTES-1];
    reg [31:0] expected_regs [0:31];
    reg [447:0] expected_trace [0:MAX_TRACE-1];
    wire [447:0] packet = {tpc,tinsn,tnpc,{31'b0,tw},{27'b0,trd},trddata,taddr,
                            {28'b0,tmask},tdata,{28'b0,trmask},trdata,{31'b0,tt},tcause,tval};

    integer imode, dmode, seed, warm_reset;
    reg [31:0] rng_i, rng_d;
    reg ibusy, dbusy;
    integer icount, dcount;
    function automatic integer delay_value(input integer mode, input reg [31:0] rng);
        case (mode)
            0: delay_value = 0;
            1: delay_value = 1;
            2: delay_value = rng % 8;
            default: delay_value = 12;
        endcase
    endfunction
    assign ir = !rst && (ibusy ? icount == 0 : delay_value(imode,rng_i) == 0);
    assign dr = !rst && (dbusy ? dcount == 0 : delay_value(dmode,rng_d) == 0);
    assign ie = ia >= FAULT_BASE;
    assign de = da >= FAULT_BASE;
    assign idata = ie ? 32'b0 : {mem[ia+3],mem[ia+2],mem[ia+1],mem[ia]};
    assign idata_second=ia+4>=FAULT_BASE?32'b0:{mem[ia+7],mem[ia+6],mem[ia+5],mem[ia+4]};
    wire [31:0] aligned_daddr = da & 32'hfffffffc;
    assign rdata = de ? 32'b0 : {mem[aligned_daddr+3],mem[aligned_daddr+2],mem[aligned_daddr+1],mem[aligned_daddr]};
    integer lane;
    always @(posedge clk) begin
        if (rst) begin
            ibusy <= 0; dbusy <= 0; icount <= 0; dcount <= 0;
            rng_i <= seed; rng_d <= seed ^ 32'h95ab71e3;
        end else begin
            if (iv && ir) begin
                ibusy <= 0; rng_i <= rng_i * 32'd1664525 + 32'd1013904223;
            end else if (iv && !ibusy) begin
                ibusy <= 1; icount <= delay_value(imode,rng_i) - 1;
            end else if (ibusy && icount > 0) icount <= icount - 1;
            if (dv && dr) begin
                dbusy <= 0; rng_d <= rng_d * 32'd1664525 + 32'd1013904223;
                if (dw && !de)
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (ws[lane]) mem[aligned_daddr+lane] <= wd[8*lane +: 8];
            end else if (dv && !dbusy) begin
                dbusy <= 1; dcount <= delay_value(dmode,rng_d) - 1;
            end else if (dbusy && dcount > 0) dcount <= dcount - 1;
        end
    end

    string manifest, results_path, trace_path, name, image_path, gold_path;
    integer mf, rf, tf, nscan, expected_count, index, passed, total_packets;
    integer j, wait_cycles, reads, writes, expected_reads, expected_writes;
    integer fwd_mem, fwd_wb, held_wb, drained_fetch, full_pipe;
    reg checking = 0, trap_seen=0;
    reg [63:0] trapped_retired,trapped_cycles;
    reg prev_iwait, prev_dwait;
    reg [31:0] prev_ia;
    reg [68:0] prev_dpayload;
    reg [31:0] expected_halt_pc, expected_halt_cause, expected_halt_tval;
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            prev_iwait = 0; prev_dwait = 0;
        end else if (checking) begin
            if (prev_iwait && (!iv || ia !== prev_ia))
                $fatal(1,"Instruction request changed while waiting: %s",name);
            if (prev_dwait && (!dv || {dw,da,wd,ws} !== prev_dpayload))
                $fatal(1,"Data request changed while waiting: %s",name);
            prev_iwait = iv && !ir; prev_ia = ia;
            prev_dwait = dv && !dr; prev_dpayload = {dw,da,wd,ws};
            if (iv && |ia[1:0]) $fatal(1,"Misaligned fetch request");
            if (dv && dr) begin
                if (dw) writes = writes + 1;
                else reads = reads + 1;
            end
            if (dut.x_fire && dut.m_valid && dut.m_we && !dut.m_load && !dut.m_trap && dut.m_rd != 0 &&
                ((dut.x_use1 && dut.x_rs1 == dut.m_rd) || (dut.x_use2 && dut.x_rs2 == dut.m_rd)))
                fwd_mem = fwd_mem + 1;
            if (dut.x_fire && tw &&
                ((dut.x_use1 && dut.x_rs1 == trd) || (dut.x_use2 && dut.x_rs2 == trd)))
                fwd_wb = fwd_wb + 1;
            if (dut.x_valid && !dut.x_fire && tw &&
                ((dut.x_use1 && dut.x_rs1 == trd) || (dut.x_use2 && dut.x_rs2 == trd)))
                held_wb = held_wb + 1;
            if (dut.fetch.killed && iv && ir) drained_fetch = drained_fetch + 1;
            if (iv && dut.id_valid && dut.x_valid && dut.m_valid && dut.w_valid) full_pipe = full_pipe + 1;
            if(tv2 && (!tv || tt || trap_seen)) $fatal(1,"Secondary retirement bypassed older instruction/trap");
            if(tv2 && (tpc2!==tnpc || tpc2!==tpc+4)) $fatal(1,"Unordered retirement pair");
            if (tv && !trap_seen) begin
                if (index >= expected_count) $fatal(1,"Extra retire packet: %s",name);
                if (packet !== expected_trace[index]) begin
                    $display("DIFF %s index=%0d pc=%08x insn=%08x",name,index,tpc,tinsn);
                    $display("expected=%0112x",expected_trace[index]);
                    $display("actual  =%0112x",packet);
                    $fatal(1,"Architectural differential mismatch");
                end
                $fdisplay(tf,"%s %0d %0d %0112x",name,index,cycles,packet);
                if (tw) expected_regs[trd] = trddata;
                if (|tmask) begin
                    expected_writes = expected_writes + 1;
                    for (k = 0; k < 4; k = k + 1)
                        if (tmask[k]) expected_mem[(taddr & 32'hfffffffc)+k] = tdata[8*k +: 8];
                end
                if (|trmask) expected_reads = expected_reads + 1;
                if (tt) begin
                    trap_seen=1; trapped_retired=retired; trapped_cycles=cycles;
                    expected_halt_pc = tpc; expected_halt_cause = tcause; expected_halt_tval = tval;
                    if (tcause == 5) expected_reads = expected_reads + 1;
                    if (tcause == 7) expected_writes = expected_writes + 1;
                end
                index = index + 1;
            end
            if(tv2 && !trap_seen) begin
                if(index>=expected_count || packet2!==expected_trace[index]) begin
                    $display("DIFF_SECOND %s index=%0d expected=%0112x actual=%0112x",name,index,expected_trace[index],packet2);
                    $fatal(1,"Secondary architectural differential mismatch");
                end
                $fdisplay(tf,"%s %0d %0d %0112x",name,index,cycles,packet2);
                if(tw2) expected_regs[trd2]=trddata2;
                if(|tmask2)begin
                    expected_writes=expected_writes+1;
                    for(k=0;k<4;k=k+1)if(tmask2[k])expected_mem[(taddr2 & 32'hfffffffc)+k]=tdata2[8*k+:8];
                end
                if(|trmask2)expected_reads=expected_reads+1;
                index=index+1;pair_packets=pair_packets+1;
            end
        end
    end

    task automatic initialize_case;
        begin
            @(negedge clk); rst = 1; checking = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            for (j = 0; j < MEM_BYTES; j = j + 1) mem[j] = 0;
            $readmemh(image_path,mem);
            mem['he000]=8'h6f; mem['he001]=0; mem['he002]=0; mem['he003]=0;
            for (j = 0; j < MEM_BYTES; j = j + 1) expected_mem[j] = mem[j];
            for (j = 0; j < 32; j = j + 1) expected_regs[j] = 0;
            $readmemh(gold_path,expected_trace,0,expected_count-1);
            index = 0; pair_packets=0; wait_cycles = 0; trap_seen=0; trapped_retired=0; trapped_cycles=0; reads = 0; writes = 0;
            expected_reads = 0; expected_writes = 0;
            fwd_mem = 0; fwd_wb = 0; held_wb = 0; drained_fetch = 0; full_pipe = 0;
            expected_halt_pc = 0; expected_halt_cause = 0; expected_halt_tval = 0;
            rst = 0; checking = 1;
        end
    endtask

    initial begin
        if (!$value$plusargs("MANIFEST=%s",manifest)) $fatal(1,"MANIFEST required");
        if (!$value$plusargs("RESULTS=%s",results_path)) $fatal(1,"RESULTS required");
        if (!$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"TRACE required");
        mf = $fopen(manifest,"r"); rf = $fopen(results_path,"w"); tf = $fopen(trace_path,"w");
        if (!mf || !rf || !tf) $fatal(1,"Cannot open regression files");
        $fdisplay(rf,"name,packets,cycles,instret,load_stalls,data_waits,fetch_waits,redirects,mem_forward,wb_forward,held_wb,drained_fetch,full_pipeline,reads,writes,pairs");
        passed = 0; total_packets = 0;
        while (!$feof(mf)) begin
            nscan = $fscanf(mf,"%s %s %s %d %d %d %d %d\n",name,image_path,gold_path,expected_count,imode,dmode,seed,warm_reset);
            if (nscan == 8) begin
                initialize_case();
                if(warm_reset==2) begin
                    while(!dut.md_issued && wait_cycles<1000) begin @(posedge clk); #1; wait_cycles=wait_cycles+1; end
                    if(!dut.md_issued) $fatal(1,"Reset never reached M operation");
                    initialize_case();
                end
                if (warm_reset == 1) begin
                    while (!(dv && !dr) && wait_cycles < 500) begin
                        @(posedge clk); #1; wait_cycles = wait_cycles + 1;
                    end
                    if (!(dv && !dr)) $fatal(1,"Reset test never reached pending data transaction");
                    initialize_case();
                end
                while (!trap_seen && wait_cycles < 2000000) begin
                    @(posedge clk); #1; wait_cycles = wait_cycles + 1;
                end
                if (!trap_seen) $fatal(1,"Timeout: %s",name);
                checking=0;
                if (index != expected_count) $fatal(1,"Missing retire packets: %s %0d/%0d",name,index,expected_count);
                if ({halt_pc,halt_cause,halt_tval} !== {expected_halt_pc,expected_halt_cause,expected_halt_tval})
                    $fatal(1,"Latched trap information mismatch: %s",name);
                // Drain an already-issued speculative fetch. No new data side effects.
                repeat (20) begin
                    @(posedge clk); #1;
                    if (dv || tt) $fatal(1,"Side effect or repeated trap in handler loop: %s",name);
                end
                if(dut.md_valid || !dut.md_ready || dut.md_issued) $fatal(1,"M operation survived trap drain");
                if (halted || dut.csrfile.mepc !== expected_halt_pc || dut.csrfile.mcause !== expected_halt_cause || dut.csrfile.mtval !== expected_halt_tval) $fatal(1,"Machine trap CSR mismatch: %s",name);
                if (reads != expected_reads || writes != expected_writes)
                    $fatal(1,"Extra/missing data transaction: %s R=%0d/%0d W=%0d/%0d",name,reads,expected_reads,writes,expected_writes);
                for (j = 0; j < MEM_BYTES; j = j + 1)
                    if (mem[j] !== expected_mem[j]) $fatal(1,"Memory side-effect mismatch %s addr=%08x actual=%02x expected=%02x",name,j,mem[j],expected_mem[j]);
                for (j = 0; j < 32; j = j + 1)
                    if (dut.regfile.regs[j] !== expected_regs[j]) $fatal(1,"Final register mismatch %s x%0d",name,j);
                if (trapped_retired != expected_count-1) $fatal(1,"Retired counter counts traps or duplicates: %s",name);
                $fdisplay(rf,"%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",name,index,trapped_cycles,trapped_retired,load_stalls,dwaits,iwaits,redirects,fwd_mem,fwd_wb,held_wb,drained_fetch,full_pipe,reads,writes,pair_packets);
                $display("PASS %s packets=%0d cycles=%0d",name,index,cycles);
                passed = passed + 1; total_packets = total_packets + index;
                @(negedge clk); checking = 0; rst = 1;
            end else if (nscan != -1) $fatal(1,"Malformed manifest record");
        end
        $fclose(mf); $fclose(rf); $fclose(tf);
        $display("REGRESSION_PASS cases=%0d packets=%0d",passed,total_packets);
        $finish;
    end
endmodule
