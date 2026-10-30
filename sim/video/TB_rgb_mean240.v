`timescale 1ns/1ps
module TB_rgb_mean240;
    reg clk=0,rst_n=0,valid=0;
    always #5 clk=~clk;
    reg [15:0] r=0,g=0,b=0;
    reg [6:0] x=0,y=0;
    wire ov,busy;
    wire [23:0] rgb;
    wire [6:0] ox,oy;
    rgb_mean240 dut(.clk(clk),.rst_n(rst_n),.clear(1'b0),.in_valid(valid),
        .sum_r(r),.sum_g(g),.sum_b(b),.in_x(x),.in_y(y),
        .out_valid(ov),.out_rgb(rgb),.out_x(ox),.out_y(oy),.busy(busy));
    reg [37:0] expected[0:61200];
    integer tail=0,head=0,n;
    function [7:0] golden;input integer total;integer q,m;begin
        q=total/240;m=total%240;golden=8'(q+((m>120)||(m==120&&q%2==1)));
    end endfunction
    always @(posedge clk)if(rst_n)begin
        if(valid)begin expected[tail]={x,y,golden(r),golden(g),golden(b)};tail=tail+1;end
        #1;
        if(ov)begin
            if(head>=tail || {ox,oy,rgb}!==expected[head])$fatal(1,"mean mismatch at %0d",head);
            head=head+1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(n=0;n<=61200;n=n+1)begin
            @(negedge clk);valid=1;r=16'(n);g=16'((n*37)%61201);b=16'(61200-n);
            x=7'(n);y=7'(n>>7);
            if(n%17==0)begin @(negedge clk);valid=0;end
        end
        @(negedge clk);valid=0;repeat(6)@(negedge clk);
        if(head!=61201||busy)$fatal(1,"mean count or pipeline drain");
        $display("PASS mean240: all 61201 valid sums, RGB, tags, bubbles and ties-to-even");$finish;
    end
endmodule
