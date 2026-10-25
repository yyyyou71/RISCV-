`timescale 1ns/1ps
module tb_machine;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,irq_timer=0;
    wire iv,ir,ie,dv,dw,dr,de,irq_taken,retire,exception;
    wire [31:0] ia,idata,da,wd,rdata,pc,npc,insn;
    wire [3:0] ws;
    rv32_core dut(.clk(clk),.rst(rst),.irq_timer(irq_timer),.interrupt_taken(irq_taken),
        .imem_valid(iv),.imem_addr(ia),.imem_ready(ir),.imem_rdata(idata),.imem_error(ie),
        .dmem_valid(dv),.dmem_write(dw),.dmem_addr(da),.dmem_wdata(wd),.dmem_wstrb(ws),
        .dmem_ready(dr),.dmem_rdata(rdata),.dmem_error(de),.retire_valid(retire),.retire_trap(exception),
        .retire_pc(pc),.retire_next_pc(npc),.retire_insn(insn));
    reg [7:0] mem[0:65535];
    integer imode,dmode,scene,expected_irq,expected_trap,icount,dcount;
    reg ibusy=0,dbusy=0;
    reg [31:0] rng=32'h812fea49;
    function automatic integer delay(input integer mode,input [31:0] random_value);
        case(mode) 0:delay=0; 1:delay=1; 2:delay=random_value%7+1; default:delay=12; endcase
    endfunction
    assign ir=!rst && (ibusy?icount==0:delay(imode,rng)==0);
    assign dr=!rst && (dbusy?dcount==0:delay(dmode,rng>>8)==0);
    assign ie=ia>=32'hf000;
    assign de=da>=32'hf000 && da!=32'hfff0;
    assign idata=ie?0:{mem[ia+3],mem[ia+2],mem[ia+1],mem[ia]};
    wire [31:0] aligned=da & 32'hfffffffc;
    assign rdata=de?0:{mem[aligned+3],mem[aligned+2],mem[aligned+1],mem[aligned]};
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
            if(iv&&ir) begin ibusy<=0; rng<=rng*1664525+1013904223; end
            else if(iv&&!ibusy) begin ibusy<=1; icount<=delay(imode,rng)-1; end
            else if(ibusy&&icount>0) icount<=icount-1;
            if(dv&&dr) begin
                dbusy<=0;
                if(da==32'h8000) begin if(dw) writes8000=writes8000+1; else reads8000=reads8000+1; end
                if(dw&&!de) begin
                    for(k=0;k<4;k=k+1) if(ws[k]) mem[aligned+k]<=wd[8*k+:8];
                    if(da==32'hfff0) begin
                        if(wd!=1) $fatal(1,"Guest assertion failed pc=%08x cause=%08x mepc=%08x",pc,dut.csrfile.mcause,dut.csrfile.mepc);
                        done=1;
                    end
                end
            end else if(dv&&!dbusy) begin dbusy<=1; dcount<=delay(dmode,rng>>8)-1; end
            else if(dbusy&&dcount>0) dcount<=dcount-1;
            if(scene==6 && !started && dut.x_valid && dut.x_insn==32'h30047073) begin
                started=1; irq_timer<=1;
            end else if(scene>=2 && scene<=5 && !started && dv && !dr && da==(scene==5?32'hf000:32'h8000)) begin
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
        $fdisplay(rf,"name,cycles,interrupts,exceptions,mret,reads8000,writes8000,bp_hits,bp_mispredictions");
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
                if(scene==3 && writes8000!=1) $fatal(1,"Interrupted store duplicated");
                $fdisplay(rf,"%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",name,cycles,irqs,traps,returns,reads8000,writes8000,dut.bp_hits,dut.bp_mispredictions);
                $display("MACHINE_CASE_PASS %s",name); cases=cases+1;
            end
        end
        $fclose(mf); $fclose(rf); $display("MACHINE_REGRESSION_PASS cases=%0d",cases); $finish;
    end
endmodule
