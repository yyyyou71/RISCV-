`timescale 1ns/1ps
module TB_add_pipeline;
    reg clk=0,rst_n=0,iv=0,ready=0;
    always #4 clk=~clk;
    reg signed [15:0] a,b;
    reg [31:0] ma,mb,sa,sb;
    wire ir,ov,error;
    wire [15:0] data;
    add_int16 dut(clk,rst_n,iv,ir,a,b,ma,sa,mb,sb,ov,ready,data,error);
    function signed [63:0] rhu;
        input signed [63:0] value;
        input [5:0] shift;
        begin rhu=shift==0?value:(value+($signed(64'd1)<<(shift-6'd1)))>>>shift;end
    endfunction
    reg signed [63:0] sum;
    reg [15:0] expected;
    reg bad;
    integer n,waits;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<256;n=n+1)begin
            a=$random;b=$random;ma=$random;mb=$random;sa=n%64;sb=(n*13)%64;
            if(n%3!=0)begin ma[31]=0;mb[31]=0;end
            if(n%17==0)sa=64;
            bad=ma[31] || mb[31] || sa>63 || sb>63;
            sum=rhu($signed(a)*$signed({1'b0,ma}),sa[5:0])+rhu($signed(b)*$signed({1'b0,mb}),sb[5:0]);
            expected=bad?0:sum>64'sd32767?16'h7fff:sum< -64'sd32767?16'h8001:sum[15:0];
            iv=1;@(negedge clk);iv=0;a=0;b=0;ma=0;mb=0;sa=0;sb=0;
            waits=0;while(!ov)begin @(negedge clk);waits=waits+1;if(waits>10)$fatal(1,"ADD timeout");end
            repeat(n%3+1)begin
                if(data!==expected || error!==bad || !ov || ir)$fatal(1,"ADD numeric/hold mismatch case=%0d",n);
                @(negedge clk);
            end
            ready=1;@(negedge clk);ready=0;
        end
        $display("PASS ADD pipeline: 256 signed/shift/saturation/invalid cases, snapshot and stalls");$finish;
    end
endmodule
