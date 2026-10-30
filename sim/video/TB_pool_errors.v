`timescale 1ns/1ps
module TB_pool_errors;
    reg clk=0,rst_n=0,start=0,cancel=0,vs=0,de=0,out_ready=1;
    reg [23:0] rgb=24'hff1103;
    always #3 clk=~clk;
    wire ready,busy,frame_start,done,error,valid,last;
    wire [3:0] code;
    wire [31:0] id;
    wire [127:0] data;
    wire [15:0] beats;
    integer completed=0,last_code=0,checked=0;
    reg check_pixels=0;
    rgb888_pool96 #(.TIMEOUT_CYCLES(100000)) dut(.clk(clk),.rst_n(rst_n),.start(start),.cancel(cancel),
        .vs(vs),.de(de),.rgb(rgb),.source_frame_id(32'hffffffff),.ready(ready),.busy(busy),
        .frame_start(frame_start),.done(done),.error(error),.error_code(code),.result_frame_id(id),
        .out_valid(valid),.out_ready(out_ready),.out_data(data),.out_last(last),.out_beats(beats));
    always @(posedge clk)if(rst_n)begin
        if(check_pixels&&valid&&out_ready)begin
            if(data!==(checked%2 ? 128'b0:128'h000000000000000000000003001100ff))
                $fatal(1,"uninitialized/stale accumulator, beat %0d data %h",checked,data);
            checked=checked+1;
        end
        #1;
        if(done)begin
            if(!error)$fatal(1,"malformed transaction accepted");
            completed=completed+1;last_code=code;
        end
    end
    task arm;begin
        wait(ready);@(negedge clk);start=1;@(negedge clk);start=0;
    end endtask
    task mark_frame;begin
        @(negedge clk);vs=1;repeat(3)@(negedge clk);vs=0;repeat(8)@(negedge clk);
    end endtask
    task line;input integer width;integer x;begin
        for(x=0;x<width;x=x+1)begin @(negedge clk);de=1;end
        @(negedge clk);de=0;repeat(5)@(negedge clk);
    end endtask
    task expect_error;input integer count,wanted;begin
        repeat(12)@(negedge clk);
        if(completed!=count||last_code!=wanted||!ready||valid)
            $fatal(1,"expected error %0d at transaction %0d; got %0d/%0d",wanted,count,completed,last_code);
    end endtask
    integer y;
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        arm();wait(done);expect_error(1,4); // missing VS timeout
        arm();mark_frame();line(1919);expect_error(2,1);
        arm();mark_frame();line(1921);expect_error(3,1);
        arm();mark_frame();check_pixels=1;checked=0;
        for(y=0;y<12;y=y+1)line(1920);
        repeat(30)@(negedge clk);
        if(checked!=192)$fatal(1,"first pooled row incomplete: %0d",checked);
        check_pixels=0;mark_frame();expect_error(4,1); // partial output never commits
        arm();mark_frame();out_ready=0;
        for(y=0;y<12;y=y+1)line(1920);
        repeat(30)@(negedge clk);expect_error(5,2);out_ready=1;
        arm();@(negedge clk);cancel=1;@(negedge clk);cancel=0;expect_error(6,5);
        arm();mark_frame();check_pixels=1;checked=0;
        for(y=0;y<12;y=y+1)line(1920);
        repeat(30)@(negedge clk);
        if(checked!=192)$fatal(1,"recovery did not overwrite old RAM");
        check_pixels=0;@(negedge clk);cancel=1;@(negedge clk);cancel=0;expect_error(7,5);
        arm();mark_frame();line(1920);
        @(negedge clk);rst_n=0;repeat(4)@(negedge clk);
        if(!ready||valid||busy||beats!=0)$fatal(1,"reset did not clear transaction");
        $display("PASS pool errors: unknown RAM, timeout, short/long line, partial frame, blocked sink, cancel, recovery/reset");$finish;
    end
    initial begin #3000000;$fatal(1,"error test timeout");end
endmodule
