`timescale 1ns/1ps
module tb_machine;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,irq_timer=0;
    wire iv,ir,ie,dv,dw,dr,de,irq_taken,retire,exception;
    wire [31:0] ia,idata,da,wd,rdata,pc,npc,insn;
    wire [3:0] ws;
    wire isv;wire [31:0] isdata;
    wire retire2;wire [31:0] npc2;
    rv32_core #(.M_ENABLE(1),.BP_ENABLE(1),.BP_INDEX_BITS(8),.GSHARE_ENABLE(0),.PHT_BITS(8),.RAS_DEPTH(8),.FETCH_DEPTH(4),.FETCH_BYPASS(1),.LOAD_FORWARD(1),.DUAL_ENABLE(1),.WIDE_FETCH(1),.PAIR_BRANCH(1),.PAIR_MEMORY(1),.PAIR_JALR(1),.FAST_STORE(1),.FAST_MUL(1),.PAIR_MUL(1)) dut(.clk(clk),.rst(rst),.irq_timer(irq_timer),.interrupt_taken(irq_taken),
        .imem_valid(iv),.imem_addr(ia),.imem_ready(ir),.imem_rdata(idata),.imem_error(ie),.imem_second_valid(isv),.imem_second_error(1'b0),.imem_rdata_second(isdata),
        .dmem_valid(dv),.dmem_write(dw),.dmem_addr(da),.dmem_wdata(wd),.dmem_wstrb(ws),
        .dmem_ready(dr),.dmem_rdata(rdata),.dmem_error(de),.retire2_valid(retire2),.retire2_next_pc(npc2),.retire_valid(retire),.retire_trap(exception),
        .retire_pc(pc),.retire_next_pc(npc),.retire_insn(insn));

    wire biv,bir,bie,bdv,bdw,bdr,bde;
    wire [31:0] bia,bidata,bda,bwd,brdata; wire [3:0] bws;
    wire [31:0] ih,im,dh,dm,wh,wm;
    wire icv,icr,icw,irv,irr,ire,irl; wire [31:0] ica,icd,ird; wire [3:0] ics; wire [7:0] icl;
    burst_word_test_adapter itransport(.clk(clk),.rst(rst),.cv(icv),.cr(icr),.cw(icw),.ca(ica),.cd(icd),.cs(ics),.cl(icl),.rv(irv),.rr(irr),.rd(ird),.re(ire),.rl(irl),.mv(biv),.mw(),.ma(bia),.md(),.ms(),.mr(bir),.me(bie),.mdata(bidata));
    wire dcv,dcr,dcw,drv,drr,dre,drl; wire [31:0] dca,dcd,drd; wire [3:0] dcs; wire [7:0] dcl;
    burst_word_test_adapter dtransport(.clk(clk),.rst(rst),.cv(dcv),.cr(dcr),.cw(dcw),.ca(dca),.cd(dcd),.cs(dcs),.cl(dcl),.rv(drv),.rr(drr),.rd(drd),.re(dre),.rl(drl),.mv(bdv),.mw(bdw),.ma(bda),.md(bwd),.ms(bws),.mr(bdr),.me(bde),.mdata(brdata));

    rv32_icache #(.BURST_INTERFACE(1),.WIDE_FETCH(1),.ENABLE(1),.ROM_BYTES(32'hf000)) icache (
        .clk(clk),.rst(rst),.valid(iv),.addr(ia),.ready(ir),.rdata(idata),.error(ie),.second_valid(isv),.rdata_second(isdata),
        .mem_valid(),.mem_addr(),.mem_ready(1'b0),.mem_rdata(32'b0),.mem_error(1'b0),
        .cmd_valid(icv),.cmd_ready(icr),.cmd_write(icw),.cmd_addr(ica),.cmd_wdata(icd),.cmd_wstrb(ics),.cmd_len(icl),.rsp_valid(irv),.rsp_ready(irr),.rsp_data(ird),.rsp_error(ire),.rsp_last(irl),.read_hits(ih),.read_misses(im),.refill_words(),.refill_errors());
    rv32_dcache #(.BURST_INTERFACE(1),.ENABLE(1),.ROM_BYTES(32'h8000),.RAM_BASE(32'h8000),.RAM_BYTES(32'h7000)) dcache (
        .clk(clk),.rst(rst),.valid(dv),.write(dw),.addr(da),.wdata(wd),.wstrb(ws),.ready(dr),.rdata(rdata),.error(de),
        .mem_valid(),.mem_write(),.mem_addr(),.mem_wdata(),.mem_wstrb(),.mem_ready(1'b0),.mem_rdata(32'b0),.mem_error(1'b0),
        .cmd_valid(dcv),.cmd_ready(dcr),.cmd_write(dcw),.cmd_addr(dca),.cmd_wdata(dcd),.cmd_wstrb(dcs),.cmd_len(dcl),.rsp_valid(drv),.rsp_ready(drr),.rsp_data(drd),.rsp_error(dre),.rsp_last(drl),.read_hits(dh),.read_misses(dm),.write_hits(wh),.write_misses(wm),.bypass_requests(),.refill_words(),.refill_errors());
    reg biwait=0,bdwait=0; reg [31:0] prev_bia; reg [68:0] prev_bdp;
    always @(posedge clk) begin
        if(rst) begin biwait=0; bdwait=0; end
        else begin
            if(biwait && (!biv || bia!==prev_bia)) $fatal(1,"Cache instruction backend request changed");
            if(bdwait && (!bdv || {bdw,bda,bwd,bws}!==prev_bdp)) $fatal(1,"Cache data backend request changed");
            biwait=biv&&!bir; prev_bia=bia; bdwait=bdv&&!bdr; prev_bdp={bdw,bda,bwd,bws};
        end
    end
    reg [7:0] mem[0:65535];
    integer imode,dmode,scene,expected_irq,expected_trap,icount,dcount;
    reg ibusy=0,dbusy=0;
    reg [31:0] rng=32'h812fea49;
    function automatic integer delay(input integer mode,input [31:0] random_value);
        case(mode) 0:delay=0; 1:delay=1; 2:delay=random_value%7+1; default:delay=12; endcase
    endfunction
    assign bir=!rst && (ibusy?icount==0:delay(imode,rng)==0);
    assign bdr=!rst && (dbusy?dcount==0:delay(dmode,rng>>8)==0);
    assign bie=bia>=32'hf000;
    assign bde=bda>=32'hf000 && bda!=32'hfff0;
    assign bidata=bie?0:{mem[bia+3],mem[bia+2],mem[bia+1],mem[bia]};
    wire [31:0] aligned=bda & 32'hfffffffc;
    assign brdata=bde?0:{mem[aligned+3],mem[aligned+2],mem[aligned+1],mem[aligned]};
    integer k,cycles,irqs,traps,returns,done,started,pulse,reads8000,writes8000;
    reg iw,dw_wait;
    reg [31:0] previous_ia,last_next,interrupt_pc;
    reg [68:0] previous_data;
    always @(posedge clk) begin
        if(rst) begin
            ibusy<=0; dbusy<=0; icount<=0; dcount<=0; rng<=32'h812fea49;
            iw=0; dw_wait=0; cycles=0; irqs=0; traps=0; returns=0; done=0;
            started=0; pulse=0; reads8000=0; writes8000=0; last_next=0;
        end else begin
            cycles=cycles+1;
            if(iw && (!iv || ia!==previous_ia)) $fatal(1,"Instruction request changed across trap/drain");
            if(dw_wait && (!dv || {dw,da,wd,ws}!==previous_data)) $fatal(1,"Data request cancelled across trap/drain");
            iw=iv&&!ir; previous_ia=ia; dw_wait=dv&&!dr; previous_data={dw,da,wd,ws};
            if(biv&&bir) begin ibusy<=0; rng<=rng*1664525+1013904223; end
            else if(biv&&!ibusy) begin ibusy<=1; icount<=delay(imode,rng)-1; end
            else if(ibusy&&icount>0) icount<=icount-1;
            if(bdv&&bdr) begin
                dbusy<=0;
                if(bda==32'h8000) begin if(bdw) writes8000=writes8000+1; else reads8000=reads8000+1; end
                if(bdw&&!bde) begin
                    for(k=0;k<4;k=k+1) if(bws[k]) mem[aligned+k]<=bwd[8*k+:8];
                    if(bda==32'hfff0) begin
                        if(bwd!=1) $fatal(1,"Guest assertion failed pc=%08x cause=%08x mepc=%08x",pc,dut.csrfile.mcause,dut.csrfile.mepc);
                        done=1;
                    end
                end
            end else if(bdv&&!dbusy) begin dbusy<=1; dcount<=delay(dmode,rng>>8)-1; end
            else if(dbusy&&dcount>0) dcount<=dcount-1;
            if(!started && ((scene==17 && dut.md_request && dut.md_ready) ||
                (scene==18 && dut.m_extension.unit.state==3 && dut.m_extension.unit.steps==16) ||
                (scene==19 && dut.x_valid && dut.x_mop && !dut.md_issued) ||
                (scene==20 && dut.m_extension.unit.state==3 && dut.m_extension.unit.steps==1))) begin
                started=1; irq_timer<=1;
            end else if(scene>=31 && scene<=33 && !started && dv && !dr && dut.memory_in_second)begin
                started=1;irq_timer<=1;
            end else if(scene==21 && !started && dut.x_valid && dut.x2_valid && dut.x_insn==32'h01100513 && dut.x2_insn==32'h01d00593) begin
                started=1;irq_timer<=1;
            end else if((scene==22 || scene==23) && !started && dut.x_valid && dut.x2_valid && (dut.x_load || dut.x_store) && dut.x2_insn==32'h06300913) begin
                started=1;
            end else if(scene==6 && !started && dut.x_valid && dut.x_insn==32'h30047073) begin
                started=1; irq_timer<=1;
            end else if(((scene>=2 && scene<=5) || scene==7) && !started && dv && !dr && (scene!=7 || dw) && da==(scene==5?32'hf000:32'h8000)) begin
                started=1; irq_timer<=1; pulse=3;
            end else if(scene==4 && pulse>0) begin pulse=pulse-1; if(pulse==0) irq_timer<=0; end
            if(irq_taken) begin
                irqs=irqs+1; interrupt_pc=last_next;
                if(dv || dut.x_valid || dut.m_valid || dut.w_valid) $fatal(1,"Interrupt taken before pipeline drained");
                if(scene==5 && traps!=1) $fatal(1,"Interrupt bypassed older synchronous exception");
            end
            if(retire) begin
                last_next=npc;
                if(exception) traps=traps+1;
                if(insn==32'h30200073 && !exception) returns=returns+1;
            end
            if(retire2) begin
                if(!retire || exception)$fatal(1,"Invalid second retirement in machine test");
                last_next=npc2;
            end
            if(irq_taken) begin
                #1;
                if(dut.csrfile.mepc!==interrupt_pc || dut.csrfile.mcause!==32'h80000007 || dut.csrfile.mtval!==0)
                    $fatal(1,"Interrupt continuation PC/CSR mismatch");
            end
        end
    end
    string manifest,name,image_path;
    integer mf,rf,scan,cases;
    initial begin
        if(!$value$plusargs("MANIFEST=%s",manifest)) $fatal(1,"Missing manifest");
        mf=$fopen(manifest,"r"); rf=$fopen("machine_cases.csv","w"); cases=0;
        $fdisplay(rf,"name,cycles,interrupts,exceptions,mret,reads8000,writes8000,bp_hits,bp_mispredictions,icache_hits,icache_misses,dcache_hits,dcache_misses,dcache_write_hits,dcache_write_misses");
        while(!$feof(mf)) begin
            scan=$fscanf(mf,"%s %s %d %d %d %d %d\n",name,image_path,imode,dmode,scene,expected_irq,expected_trap);
            if(scan==7) begin
                @(negedge clk); rst=1; irq_timer=0;
                repeat(3) @(posedge clk);
                @(negedge clk);
                for(k=0;k<65536;k=k+1) mem[k]=0;
                $readmemh(image_path,mem);
                mem['h8000]='h44; mem['h8001]='h33; mem['h8002]='h22; mem['h8003]='h11;
                rst=0; irq_timer=(scene==1);
                while(!done && cycles<1000000) begin @(posedge clk); #2; end
                if(!done) $fatal(1,"Machine test timeout %s pc=%08x cause=%08x epc=%08x",name,pc,dut.csrfile.mcause,dut.csrfile.mepc);
                if(irqs!=expected_irq || traps!=expected_trap || returns!=irqs+traps) $fatal(1,"Trap/return count mismatch %s IRQ=%0d TRAP=%0d RET=%0d",name,irqs,traps,returns);
                if(scene>=2 && !started) $fatal(1,"Pending data interrupt scenario not reached");
                if((scene==2 || scene==4) && reads8000!=1) $fatal(1,"Interrupted load duplicated");
                if((scene==3 || scene==7) && writes8000!=1) $fatal(1,"Interrupted store duplicated");
                $fdisplay(rf,"%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",name,cycles,irqs,traps,returns,reads8000,writes8000,dut.bp_hits,dut.bp_mispredictions,ih,im,dh,dm,wh,wm);
                $display("MACHINE_CASE_PASS %s",name); cases=cases+1;
            end
        end
        $fclose(mf); $fclose(rf); $display("MACHINE_REGRESSION_PASS cases=%0d",cases); $finish;
    end
endmodule
