`timescale 1ns/1ps
module TB_ai_vendor_multadd;
    reg clk=0,rst=1,ce=1;
    reg [15:0] a0=0,a1=0;
    reg [7:0] b0=0,b1=0;
    wire [24:0] p;
    reg signed [24:0] expected[0:2];
    integer n,checked=0;
    GTP_GRS GRS_INST(.GRS_N(1'b1));
    multiply_adder_w8a16 dut(.clk(clk),.rst(rst),.ce(ce),.addsub(1'b0),
        .a0(a0),.a1(a1),.b0(b0),.b1(b1),.p(p));
    always #5 clk=~clk;
    always @(posedge clk)begin
        if(rst)begin expected[0]=0;expected[1]=0;expected[2]=0;end
        else if(ce)begin
            expected[2]=expected[1];expected[1]=expected[0];
            expected[0]=$signed(a0)*$signed(b0)+$signed(a1)*$signed(b1);
        end
        #1;
        if(p!==expected[2])$fatal(1,"vendor signed 16x8 pair / 3 CE stages mismatch got=%h expected=%h",p,expected[2]);
        checked=checked+1;
    end
    initial begin
        for(n=0;n<100;n=n+1)begin
            @(negedge clk);rst=n<3 || n==43;ce=n%7!=2;
            a0=n%2 ? -32768:n*127;a1=n%3 ? 32767:-n*219;
            b0=n%2 ? -128:n;b1=n%3 ? 127:-n;
        end
        @(negedge clk);
        $display("PASS vendor AI Multiply-Adder: signed extrema, 3 CE stages, stalls/reset, %0d checks",checked);
        $finish;
    end
endmodule
