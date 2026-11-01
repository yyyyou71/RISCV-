`timescale 1ns/1ps
module TB_hdmi_line_pad;
    reg clk=0,rst_n=0,vs=0,de=0;
    reg [23:0] rgb=0;
    always #3 clk=~clk;
    wire ovs,ode;
    wire [23:0] orgb;
    integer x=0,row=0,i,width,source_row;
    reg old_de=0,previous_vs=0;
    hdmi_line_pad #(.OUT_PIX(16)) dut(.clk(clk),.rst_n(rst_n),.vs(vs),.de(de),.rgb(rgb),
        .out_vs(ovs),.out_de(ode),.out_rgb(orgb));
    function [23:0] pixel;input integer yy,xx;begin pixel=24'h314100+yy*256+xx;end endfunction
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            if(ovs!==vs)$fatal(1,"VS was not registered with the pixel stream");
            if(ode)begin
                width=15+row;
                if(x>=16 || orgb!==(x<width ? pixel(row,x):24'b0))
                    $fatal(1,"line/pixel mismatch row=%0d x=%0d rgb=%h",row,x,orgb);
                x=x+1;
            end
            if(old_de&&!ode)begin
                if(x!=16)$fatal(1,"output line length %0d",x);
                x=0;row=row+1;
            end
            old_de=ode;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
        vs=1;repeat(3)@(negedge clk);vs=0;repeat(4)@(negedge clk);
        for(source_row=0;source_row<3;source_row=source_row+1)begin
            for(i=0;i<15+source_row;i=i+1)begin
                @(negedge clk);de=1;rgb=pixel(source_row,i);
            end
            @(negedge clk);de=0;rgb=24'hffffff;
            repeat(6)@(negedge clk);
        end
        if(row!=3)$fatal(1,"missing lines");
        rst_n=0;repeat(3)@(negedge clk);
        if(ode||ovs||orgb!=0)$fatal(1,"reset did not clear stream");
        $display("PASS HDMI padding: first/last pixels preserved, black tail, exact width, truncate, reset");
        $finish;
    end
    initial begin #10000;$fatal(1,"line padding timeout");end
endmodule
