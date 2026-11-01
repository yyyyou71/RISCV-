`timescale 1ns/1ps
module TB_ai_address_pipeline;
    reg clk=0,rst_n=0,clear=0,iv=0,ready=0;
    always #4 clk=~clk;
    reg [31:0] a,b,c,pitch,inner,base;
    reg [1:0] shift;
    wire ir,ov;
    wire [31:0] address;
    ai_address_math dut(clk,rst_n,clear,iv,ir,ov,ready,a,b,c,pitch,inner,base,shift,address);
    reg [31:0] expected,hold_address;
    integer n,waits;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<256;n=n+1)begin
            a=$random;b=$random;c=$random;pitch=$random;inner=$random;base=$random;shift=n%4;
            expected=((((a*b)+c)*pitch+inner)<<shift)+base;
            iv=1;@(negedge clk);iv=0;
            a=32'hdeadbeef;b=0;c=0;pitch=0;inner=0;base=0;
            waits=0;while(!ov)begin @(negedge clk);waits=waits+1;if(waits>32)$fatal(1,"address timeout");end
            if(address!==expected)$fatal(1,"address mismatch case=%0d got=%h expected=%h",n,address,expected);
            hold_address=address;
            repeat(n%4)begin @(negedge clk);if(!ov || ir || address!==hold_address)$fatal(1,"unstable stalled address");end
            ready=1;@(negedge clk);ready=0;
            if(ov || !ir)$fatal(1,"address result not consumed exactly once");
        end
        iv=1;@(negedge clk);iv=0;repeat(3)@(negedge clk);clear=1;
        @(negedge clk);clear=0;repeat(20)begin @(negedge clk);if(ov)$fatal(1,"stale address after clear");end
        $display("PASS address pipeline: 256 full-width cases, snapshot, wrap, stalls, cancel");$finish;
    end
endmodule
