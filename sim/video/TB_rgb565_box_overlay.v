`timescale 1ns/1ps
module TB_rgb565_box_overlay;
    reg clk=0,rst_n=0,frame_start=0,in_valid=0;
    always #5 clk=~clk;
    reg [127:0] in_data=0;
    reg [4:0] box_count=0;
    reg [1023:0] boxes=0;
    wire out_valid;wire [127:0] out_data;
    rgb565_box_overlay #(.WIDTH(32),.HEIGHT(8)) dut(.*);
    reg [127:0] expected[0:127];integer put=0,get=0,lane,b,x,y,word,pass;
    integer x0,y0,x1,y1;reg found;reg [15:0] color;
    always @(negedge clk)if(out_valid)begin
        if(out_data!==expected[get])$fatal(1,"overlay word %0d: %h != %h",get,out_data,expected[get]);
        get=get+1;
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        boxes[0+:64]={4'b0,16'h07e0,11'd6,11'd28,11'd1,11'd2};
        boxes[64+:64]={4'b0,16'hf800,11'd7,11'd31,11'd0,11'd8};
        boxes[15*64+:64]={4'b0,16'h001f,11'd7,11'd31,11'd7,11'd0};
        for(pass=0;pass<2;pass=pass+1)begin
            @(negedge clk);frame_start=1;box_count=pass?0:16;
            @(negedge clk);frame_start=0;
            for(word=0;word<32;word=word+1)begin
                if(word%3==1)begin in_valid=0;@(negedge clk);end
                in_valid=1;x=(word%4)*8;y=word/4;
                for(lane=0;lane<8;lane=lane+1)begin
                    in_data[lane*16+:16]=word*8+lane;found=0;color=word*8+lane;
                    for(b=0;b<16;b=b+1)begin
                        x0=boxes[b*64+:11];y0=boxes[b*64+11+:11];x1=boxes[b*64+22+:11];y1=boxes[b*64+33+:11];
                        if(!found && b<box_count && x+lane>=x0 && x+lane<=x1 && y>=y0 && y<=y1 &&
                           (x+lane-x0<2 || x1-x-lane<2 || y-y0<2 || y1-y<2))begin
                            found=1;color=boxes[b*64+44+:16];
                        end
                    end
                    expected[put][lane*16+:16]=color;
                end
                put=put+1;@(negedge clk);
            end
            in_valid=0;repeat(5)@(negedge clk);
        end
        if(get!=put)$fatal(1,"dropped output: %0d/%0d",get,put);
        $display("PASS overlay: 512 pixels, gaps, overlap priority, 16 boxes and bypass");$finish;
    end
    initial begin #20000;$fatal(1,"overlay timeout");end
endmodule
