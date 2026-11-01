`timescale 1ns/1ps
module TB_ai_config_sizes;
    reg clk=0,rst_n=0,start=0;
    always #4 clk=~clk;
    reg [15:0] h,w;
    reg [31:0] ci,co,oh,ow,op,cb;
    reg [1:0] kernel;
    reg quantized;
    wire done8,done16;
    wire [63:0] i8,w8,o8,a8,b8,c8,i16,w16,o16,a16,b16,c16;
    ai_config_sizes #(.ACT_WIDTH(8)) d8(clk,rst_n,start,h,w,ci,co,oh,ow,op,cb,kernel,quantized,done8,i8,w8,o8,a8,b8,c8);
    ai_config_sizes #(.ACT_WIDTH(16)) d16(clk,rst_n,start,h,w,ci,co,oh,ow,op,cb,kernel,quantized,done16,i16,w16,o16,a16,b16,c16);
    reg [63:0] area,ie,we,oe,be,ce;
    integer n,waits;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<128;n=n+1)begin
            h=$random;w=$random;ci=$random;co=$random;oh=$random;ow=$random;op=$random;cb=$random;
            kernel=n%4;quantized=n%2;
            if(n==0)begin h=65535;w=65535;ci=65536;co=65536;oh=65537;ow=65537;op=65536;cb=32'hfffffff0;end
            area={48'd0,h}*{48'd0,w};ie=area*{32'd0,ci};
            we={32'd0,co}*{62'd0,kernel}*{62'd0,kernel}*{32'd0,ci};
            oe={32'd0,oh}*{32'd0,ow}*{32'd0,op};be=area*{32'd0,cb}*64'd2;ce=area*{32'd0,op}*64'd2;
            start=1;@(negedge clk);start=0;waits=0;
            while(!done8 || !done16)begin @(negedge clk);waits=waits+1;if(waits>300)$fatal(1,"config sizes timeout");end
            if(i8!==ie || i16!==(ie<<1) || w8!==we || w16!==we ||
                o8!==(quantized?oe:oe<<3) || o16!==(quantized?oe<<1:oe<<3) ||
                a8!==(ie<<1) || a16!==(ie<<1) || b8!==be || b16!==be || c8!==ce || c16!==ce)
                $fatal(1,"wide configuration arithmetic mismatch case=%0d",n);
            repeat(2)@(negedge clk);
        end
        start=1;@(negedge clk);start=0;repeat(10)@(negedge clk);rst_n=0;
        @(negedge clk);if(done8 || done16)$fatal(1,"reset did not cancel configuration");
        $display("PASS config sizes: 128 cases x W8/W16, 64-bit wrap, wide invalid inputs, reset");$finish;
    end
endmodule
