`timescale 1ns/1ps
module TB_ddr_region_check;
    reg clk=0,rst_n=0;
    always #4 clk=~clk;
    reg [1:0] valid=0,accepted=0;
    reg [55:0] address=0;
    reg [7:0] length=0;
    wire [1:0] qualified;
    wire fault;
    ddr_region_check dut(.*);
    integer i;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        valid=3;length=8'hff;address={28'h1ffff80,28'h0000000};
        #1;if(qualified!=0)$fatal(1,"request not registered");
        @(negedge clk);if(qualified!=3||fault)$fatal(1,"valid boundary rejected");
        repeat(10)begin @(negedge clk);if(qualified!=3)$fatal(1,"backpressure changed qualification");end
        accepted=3;@(negedge clk);accepted=0;
        // Back-to-back requests, without lowering VALID, require a fresh check.
        address={28'h2000000,28'h1ffff88};
        #1;if(qualified!=0)$fatal(1,"stale qualification used");
        repeat(3)@(negedge clk);
        if(qualified!=0||!fault)$fatal(1,"overflow accepted");
        valid=0;@(negedge clk);rst_n=0;@(negedge clk);rst_n=1;
        if(fault||qualified!=0)$fatal(1,"reset failed");
        // All lengths at the exact top boundary, then one native unit beyond.
        for(i=0;i<16;i=i+1)begin
            address={28'(28'h2000000-(i+1)*8),28'(28'h2000000-(i+1)*8)};
            length={4'(i),4'(i)};valid=3;
            @(negedge clk);if(qualified!=3)$fatal(1,"end boundary length %0d",i);
            accepted=3;@(negedge clk);accepted=0;
            address=address+{28'd1,28'd1};
            @(negedge clk);if(qualified!=0)$fatal(1,"crossing boundary length %0d",i);
            valid=0;@(negedge clk);
        end
        $display("PASS DDR region: registered qualification, stalled/back-to-back, all burst boundaries, overflow/reset");$finish;
    end
endmodule
