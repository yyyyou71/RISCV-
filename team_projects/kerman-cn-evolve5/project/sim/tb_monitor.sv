`timescale 1ns/1ps
module tb_monitor;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,valid=0,write=0; reg [11:0] addr=0; reg [31:0] wd=0; reg [3:0] ws=0;
    reg [319:0] live=0; wire ready,error; wire [31:0] rd;
    rv32_monitor dut(.clk(clk),.rst(rst),.valid(valid),.write(write),.addr(addr),.wdata(wd),.wstrb(ws),.live_counts(live),.ready(ready),.error(error),.rdata(rd));
    integer cases=0,k;
    task automatic access(input bit wr,input [11:0] a,input [31:0] data,input [3:0] mask,input bit err,input [31:0] expected);
        begin
            @(negedge clk); valid=1; write=wr; addr=a; wd=data; ws=mask;
            @(posedge clk);
            if(!ready || error!==err || (!wr&&!err&&rd!==expected)) $fatal(1,"Monitor access mismatch addr=%h data=%h expected=%h error=%b/%b",a,rd,expected,error,err);
            #1; cases=cases+1;
            @(negedge clk); valid=0;
        end
    endtask
    initial begin
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        access(0,0,0,0,0,32'h43414333); access(0,4,0,0,0,31);
        access(0,8,0,0,0,25000000); access(0,12,0,0,0,1024);
        access(0,16,0,0,0,16); access(0,20,0,0,0,32); access(0,24,0,0,0,32); access(0,28,0,0,0,0);
        access(0,32,0,0,0,0);
        for(k=0;k<10;k=k+1) begin live[k*32+:32]=32'hfffffff0+k; access(0,12'h100+k*4,0,0,0,32'hfffffff0+k); access(0,12'h080+k*4,0,0,0,0); end
        access(1,12'h024,1,15,0,0); access(0,32,0,0,0,1);
        live=0;
        for(k=0;k<10;k=k+1) begin access(0,12'h080+k*4,0,0,0,32'hfffffff0+k); access(0,12'h100+k*4,0,0,0,0); end
        access(1,12'h024,1,1,1,0); access(1,12'h025,1,15,1,0); access(1,12'h024,2,15,1,0);
        access(1,0,0,15,1,0); access(1,12'h080,0,15,1,0); access(0,12'h028,0,0,1,0); access(0,12'h128,0,0,1,0);
        access(0,32,0,0,0,1); access(1,12'h024,1,15,0,0);
        for(k=0;k<10;k=k+1) access(0,12'h080+k*4,0,0,0,0);
        @(negedge clk); dut.sequence_number=32'hffffffff;
        access(1,12'h024,1,15,0,0); access(0,32,0,0,0,0);
        @(negedge clk); rst=1; repeat(2) @(posedge clk); @(negedge clk); rst=0;
        access(0,32,0,0,0,0);
        $display("MONITOR_UNIT_PASS cases=%0d",cases); $finish;
    end
endmodule
