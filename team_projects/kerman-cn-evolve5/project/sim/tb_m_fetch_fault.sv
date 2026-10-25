`timescale 1ns/1ps
module tb_m_fetch_fault;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    wire iv,ie,dv,trap,rwe,retire;
    wire ir=1'b1;
    wire [31:0] ia,pc,cause,tval,insn;
    reg [31:0] payload;
    wire [31:0] data=ia==0?32'h10000093:ia==4?32'h00008067:ia==256?payload:32'h00000013;
    assign ie=ia==256;
    rv32_core #(.M_ENABLE(1),.RESET_MTVEC(32'he000)) dut(
        .clk(clk),.rst(rst),.irq_timer(1'b0),.imem_valid(iv),.imem_addr(ia),
        .imem_ready(ir),.imem_rdata(data),.imem_error(ie),
        .dmem_valid(dv),.dmem_ready(1'b1),.dmem_rdata(32'b0),.dmem_error(1'b0),
        .retire_valid(retire),.retire_trap(trap),.retire_rd_we(rwe),.retire_pc(pc),
        .retire_insn(insn),.retire_cause(cause),.retire_tval(tval));
    integer op,n;
    initial begin
        for(op=0;op<8;op=op+1) begin
            @(negedge clk); rst=1; payload=32'h022081b3|(op<<12);
            repeat(3) @(negedge clk);
            rst=0; n=0;
            while(!trap && n<1000) begin @(negedge clk); n=n+1; end
            if(!trap) $fatal(1,"Fetch fault stalled behind M decoding op=%0d",op);
            if(pc!=256 || cause!=1 || tval!=256 || rwe || insn!=payload || dv || dut.md_issued)
                $fatal(1,"Fetch exception priority or side effect failed op=%0d",op);
        end
        $display("M_FETCH_FAULT_PASS cases=8"); $finish;
    end
endmodule
