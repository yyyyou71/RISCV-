`timescale 1ns/1ps
module tb_muldiv;
    parameter FAST=0;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,kill=0,req=0,take=0;
    reg [2:0] op; reg [31:0] a,b;
    wire ready,valid; wire [31:0] value;
    rv32_muldiv dut(.clk(clk),.rst(rst),.kill(kill),.req_valid(req),.req_ready(ready),.req_op(op),.req_a(a),.req_b(b),.rsp_valid(valid),.rsp_ready(take),.result(value));
    integer fd,scan,n=0,k,delay_cycles,stall,latency,code,cancelled=0;
    reg [31:0] av,bv,want;
    reg [31:0] held;
    task automatic start(input [2:0] f,input [31:0] x,y);
        begin
            @(negedge clk); if(!ready) $fatal(1,"MDU not ready"); op=f;a=x;b=y;req=1;
            @(negedge clk); req=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        fd=$fopen("m_vectors.txt","r"); if(!fd) $fatal(1,"Missing vectors");
        while(!$feof(fd)) begin
            scan=$fscanf(fd,"%d %h %h %h\n",code,av,bv,want);
            if(scan==4) begin
                start(code,av,bv); latency=0;
                while(!valid && latency<40) begin
                    // Changing all request fields while busy must not affect the result.
                    a=~av;b=bv^32'ha5a5a5a5;op=code^7;
                    @(negedge clk); latency=latency+1;
                    if(!valid && ready) $fatal(1,"Ready asserted before response consumed");
                end
                if(!valid || value!==want) $fatal(1,"M mismatch n=%0d op=%0d a=%08x b=%08x want=%08x got=%08x",n,code,av,bv,want,value);
                if(code<4 && latency!=(FAST?(code==0?0:1):2)) $fatal(1,"Unexpected multiply latency %0d",latency);
                held=value; stall=n%8;
                repeat(stall) begin @(negedge clk); if(!valid || ready || value!==held) $fatal(1,"Response not held"); end
                take=1; @(negedge clk); take=0; if(valid || !ready) $fatal(1,"Response did not drain exactly once");
                n=n+1;
            end
        end
        $fclose(fd);
        for(code=0;code<8;code=code+1) for(k=0;k<6;k=k+1) begin
            start(code,32'h81234567,32'h1234567);
            delay_cycles=(k<3?k:((code<4)?3:15+k));
            repeat(delay_cycles) @(negedge clk);
            if(k&1) rst=1; else kill=1;
            @(negedge clk); if(valid) $fatal(1,"Cancelled response survived");
            rst=0;kill=0;
            repeat(40) begin @(negedge clk); if(valid || !ready) $fatal(1,"Ghost operation after cancellation"); end
            cancelled=cancelled+1;
        end
        start(0,7,9); while(!valid) @(negedge clk); if(value!=63) $fatal(1,"Recovery after cancel failed");
        $display("MULDIV_UNIT_PASS vectors=%0d cancellation_cases=%0d",n,cancelled); $finish;
    end
    initial begin #20000000; $fatal(1,"MDU test watchdog"); end
endmodule
