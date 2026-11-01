`timescale 1ns/1ps
module TB_rgb888_pool96 #(parameter integer PAD_INPUT=0);
    reg clk=0,rst_n=0,start=0,vs=0,de=0;
    always #3 clk=~clk;
    reg [23:0] rgb=0;
    reg [31:0] source_id=0;
    wire ready,busy,frame_start,done,error,valid,last;
    wire [3:0] code;
    wire [31:0] id;
    wire [127:0] data;
    wire [15:0] beats;
    integer cycles=0,got=0,starts=0,pattern=0,x,y,source_width=1920;
    reg finished=0,held=0,held_last=0;
    reg [127:0] held_data;
    reg [127:0] expected[0:18431];
    reg [2047:0] golden_file;
    wire out_ready=cycles%29<23;
    wire pool_vs,pool_de;
    wire [23:0] pool_rgb;
    generate if(PAD_INPUT)begin:g_pad
        hdmi_line_pad u_pad(.clk(clk),.rst_n(rst_n),.vs(vs),.de(de),.rgb(rgb),
            .out_vs(pool_vs),.out_de(pool_de),.out_rgb(pool_rgb));
    end else begin:g_direct
        assign pool_vs=vs;assign pool_de=de;assign pool_rgb=rgb;
    end endgenerate
    rgb888_pool96 dut(.clk(clk),.rst_n(rst_n),.start(start),.cancel(1'b0),.vs(pool_vs),.de(pool_de),.rgb(pool_rgb),
        .source_frame_id(source_id),.ready(ready),.busy(busy),.frame_start(frame_start),
        .done(done),.error(error),.error_code(code),.result_frame_id(id),
        .out_valid(valid),.out_ready(out_ready),.out_data(data),.out_last(last),.out_beats(beats));
    function [23:0] pixel;input integer mode,xx,yy;integer rr,gg,bb,t;begin
        rr=0;gg=0;bb=0;
        case(mode)
            1:begin rr=255;gg=255;bb=255;end
            2:begin
                rr=(xx*17+yy*29+(xx^yy)*3)&255;
                gg=(xx*7+yy*53+(xx*yy)%251)&255;
                bb=(xx*11+yy*19+((xx>>3)^(yy*5)))&255;
            end
            3:begin
                t=yy%45;rr=(t==11||t==22||t==33)?255:0;
                gg=(yy%45==44)?255:0;bb=((xx/20)*7+yy)&255;
            end
            4:begin
                t=(xx%20)<10;rr=(xx/20)%2+t;gg=(xx/20)%2+1+t;bb=(xx/20)%2+2+t;
            end
        endcase
        pixel={8'(rr),8'(gg),8'(bb)};
    end endfunction
    always @(posedge clk)if(rst_n)begin
        cycles<=cycles+1;
        if(held && (!valid||data!==held_data||last!==held_last))$fatal(1,"stalled stream changed");
        held<=valid&&!out_ready;held_data<=data;held_last<=last;
        if(valid&&out_ready)begin
            if(got>=18432||data!==expected[got]||last!==(got==18431)||beats!=got)
                $fatal(1,"tensor mismatch pattern=%0d beat=%0d got=%032h expected=%032h",pattern,got,data,expected[got]);
            if(id!==source_id)$fatal(1,"frame id mismatch");
            got=got+1;
        end
        #1;
        if(frame_start)starts=starts+1;
        if(done)begin
            if(error||code!=0||got!=18432||starts!=1||busy)$fatal(1,"invalid completion code=%0d beats=%0d",code,got);
            finished=1;
        end
    end
    task mark_frame;begin
        @(negedge clk);vs=1;repeat(3)@(negedge clk);vs=0;repeat(8)@(negedge clk);
    end endtask
    initial begin
        if(!$value$plusargs("pattern=%d",pattern))pattern=0;
        if(!$value$plusargs("source_width=%d",source_width))source_width=1920;
        if(!$value$plusargs("golden=%s",golden_file))$fatal(1,"missing golden file");
        $readmemh(golden_file,expected);source_id=32'hf0000000+32'(pattern);
        repeat(5)@(negedge clk);rst_n=1;
        @(negedge clk);start=1;@(negedge clk);start=0;mark_frame();
        for(y=0;y<1080;y=y+1)begin
            for(x=0;x<source_width;x=x+1)begin @(negedge clk);de=1;rgb=pixel(pattern,x,y);end
            @(negedge clk);de=0;repeat(4+y%3)@(negedge clk);
        end
        mark_frame();wait(finished);repeat(4)@(negedge clk);
        if(!ready||valid)$fatal(1,"stream did not return idle");
        $display("PASS pool96: pattern=%0d source=%0dx1080 pad=%0d -> 18432 golden HWC16 beats, stalls, frame_id",pattern,source_width,PAD_INPUT);$finish;
    end
    initial begin #50000000;$fatal(1,"full frame timeout");end
endmodule
