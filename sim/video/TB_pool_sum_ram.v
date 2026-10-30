`timescale 1ns/1ps
module TB_pool_sum_ram;
`ifdef VENDOR_RAM
    GTP_GRS GRS_INST(.GRS_N(1'b1));
`endif
    reg clk=0,rst_n=0,we=0;
    always #5 clk=~clk;
    reg [6:0] wa=0,ra=127;
    reg [47:0] wd=0;
    wire [47:0] rd;
    pool_sum_ram dut(.clk(clk),.rst_n(rst_n),.wr_en(we),.wr_addr(wa),.rd_addr(ra),.wr_data(wd),.rd_data(rd));
    function [47:0] pattern;input integer n;begin pattern=48'h123456789abc^(48'h010204081020*48'(n));end endfunction
    integer n;
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        for(n=0;n<96;n=n+1)begin @(negedge clk);wa=7'(n);we=1;wd=pattern(n);end
        @(negedge clk);we=0;
        for(n=0;n<96;n=n+1)begin
            @(negedge clk);ra=7'(n);@(posedge clk);#1;
            if(rd!==pattern(n))$fatal(1,"RAM one-cycle read failed at %0d: %h",n,rd);
        end
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<96;n=n+1)begin
            @(negedge clk);ra=7'(n);@(posedge clk);#1;
            if(rd!==pattern(n))$fatal(1,"RAM reset erased contents at %0d",n);
        end
        $display("PASS pool RAM IP: 96 independent 48-bit sums, one-cycle read, reset retention");$finish;
    end
    initial begin #200000;$fatal(1,"RAM timeout");end
endmodule
