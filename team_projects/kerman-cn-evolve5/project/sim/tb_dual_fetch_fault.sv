`timescale 1ns/1ps
module tb_dual_fetch_fault;
    parameter BYPASS=1;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    wire iv,dv,retire,trap,rwe,retire2;
    wire [31:0] ia,pc,cause,tval,insn;
    reg [31:0] payload,fault_pc;
    integer tick=0,delay_mode;
    always @(posedge clk) if(rst)tick<=0;else tick<=tick+1;
    wire ready=delay_mode==0 || tick%3==2;
    function [31:0] word_at(input [31:0] a,input [31:0] fault,input [31:0] bits);
        if(a==fault) word_at=bits;
        else if(a==0) word_at=32'h01100093; // older addi x1,zero,17
        else word_at=32'h06300113; // must not retire after fault
    endfunction
    rv32_core #(.M_ENABLE(1),.RESET_MTVEC(32'he000),.DUAL_ENABLE(1),.WIDE_FETCH(1),
        .FETCH_DEPTH(4),.FETCH_BYPASS(BYPASS),.LOAD_FORWARD(1)) dut(
        .clk(clk),.rst(rst),.irq_timer(1'b0),.imem_valid(iv),.imem_addr(ia),
        .imem_ready(ready),.imem_rdata(word_at(ia,fault_pc,payload)),.imem_error(ia==fault_pc),
        .imem_second_valid(1'b1),.imem_second_error(ia+4==fault_pc),.imem_rdata_second(word_at(ia+4,fault_pc,payload)),
        .dmem_valid(dv),.dmem_ready(1'b1),.dmem_rdata(32'b0),.dmem_error(1'b0),
        .retire_valid(retire),.retire_trap(trap),.retire_rd_we(rwe),.retire_pc(pc),
        .retire_insn(insn),.retire_cause(cause),.retire_tval(tval),.retire2_valid(retire2));
    integer op,pos,n,older,cases=0;
    reg seen;
    initial begin
        for(delay_mode=0;delay_mode<2;delay_mode=delay_mode+1)
        for(pos=0;pos<2;pos=pos+1)
        for(op=0;op<12;op=op+1) begin
            @(negedge clk); rst=1;fault_pc=4*pos;
            if(op<8)payload=32'h022081b3|(op<<12);
            else case(op)
                8:payload=32'h06300113; // legal ALU
                9:payload=32'h00002103; // legal load
                10:payload=32'h00202023; // legal store
                11:payload=32'hffffffff; // illegal decode
            endcase
            repeat(3)@(negedge clk);rst=0;n=0;older=0;seen=0;
            while(!seen && n<1000)begin
                @(posedge clk);n=n+1;
                if(dv || dut.md_issued || retire2)$fatal(1,"Fault payload caused a side effect");
                if(retire)begin
                    if(trap)begin
                        if(pc!==fault_pc || cause!==1 || tval!==fault_pc || insn!==payload || rwe || older!=pos)
                            $fatal(1,"Wrong fetch exception pos=%0d op=%0d older=%0d pc=%h cause=%h tval=%h insn=%h payload=%h rwe=%b",pos,op,older,pc,cause,tval,insn,payload,rwe);
                        seen=1;
                    end else begin
                        if(pc!==0 || pos!=1 || insn!==32'h01100093 || older!=0)$fatal(1,"Unexpected older retirement");
                        older=older+1;
                    end
                end
            end
            if(!seen)$fatal(1,"Fetch fault timeout");
            #1;
            if(dut.regfile.regs[1] !== (pos==1?32'd17:32'd0) || dut.regfile.regs[2]!==0 || dut.instret!==pos)
                $fatal(1,"Architectural state changed across fetch fault");
            cases=cases+1;
        end
        $display("DUAL_FETCH_FAULT_PASS cases=%0d bypass=%0d",cases,BYPASS);$finish;
    end
endmodule
