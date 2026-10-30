`timescale 1ns/1ps
module TB_video_timing;
    reg pixel_clk=0,clk=0,rst_n=0,vs=0,de=0;
    always #3 pixel_clk=~pixel_clk;
    always #20 clk=~clk;
    wire ok;
    wire [31:0] shape,period;
    reg [31:0] fast_period;
    video_timing_monitor dut(.pixel_clk(pixel_clk),.clk(clk),.rst_n(rst_n),
        .vs(vs),.de(de),.shape_ok(ok),.shape(shape),.period_ticks(period));
    task mark_frame;begin
        @(negedge pixel_clk);vs=1;
        repeat(2)@(negedge pixel_clk);
        vs=0;repeat(20)@(negedge pixel_clk);
    end endtask
    task pixels;input integer width,height,gap;integer y;begin
        for(y=0;y<height;y=y+1)begin
            @(negedge pixel_clk);de=1;
            repeat(width)@(negedge pixel_clk);
            de=0;repeat(4)@(negedge pixel_clk);
        end
        repeat(gap)@(negedge pixel_clk);
    end endtask
    initial begin
        repeat(6)@(negedge clk);rst_n=1;mark_frame();
        pixels(1920,1080,20);mark_frame();
        if(!ok || shape!={16'd1080,16'd1920})$fatal(1,"valid geometry rejected");
        fast_period=period;
        pixels(1920,1080,4000);mark_frame();
        if(!ok || period<=fast_period)$fatal(1,"source period not measured");
        pixels(1919,1080,20);mark_frame();
        if(ok || shape!={16'd1080,16'd1919})$fatal(1,"short line accepted");
        pixels(1920,1079,20);mark_frame();
        if(ok || shape!={16'd1079,16'd1920})$fatal(1,"short frame accepted");
        pixels(1920,1080,20);mark_frame();
        if(!ok)$fatal(1,"geometry recovery failed");
        rst_n=0;repeat(3)@(negedge clk);
        if(ok || shape!=0 || period!=0)$fatal(1,"monitor reset failed");
        $display("PASS video timing: 1080p, measured period, bad line/frame rejection, recovery/reset");$finish;
    end
    initial begin #100000000;$fatal(1,"timing monitor timeout");end
endmodule
