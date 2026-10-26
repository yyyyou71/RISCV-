`timescale 1ns/1ps
module TB_add_int16;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg in_valid=0,out_ready=0;
    reg signed [15:0] in_a=0,in_b=0;
    reg [31:0] mult_a=0,shift_a=0,mult_b=0,shift_b=0;
    wire in_ready,out_valid,out_error;
    wire [15:0] out_data;
    add_int16 dut(.*);
    reg [191:0] vectors[0:2047];
    reg [16:0] held;
    integer count,n,checked=0,phase;
    task send;
        input integer index;
        begin
            @(negedge clk);in_a=vectors[index][15:0];in_b=vectors[index][31:16];
            mult_a=vectors[index][63:32];shift_a=vectors[index][95:64];mult_b=vectors[index][127:96];shift_b=vectors[index][159:128];
            if(!in_ready)$fatal(1,"ADD not ready");in_valid=1;
            @(negedge clk);in_valid=0;in_a=0;in_b=0;mult_a=0;mult_b=0;shift_a=0;shift_b=0;
        end
    endtask
    task finish;
        input integer index;
        begin
            wait(out_valid);@(negedge clk);
            if({out_error,out_data}!==vectors[index][176:160])$fatal(1,"ADD mismatch n=%0d got=%h expected=%h",index,{out_error,out_data},vectors[index][176:160]);
            held={out_error,out_data};
            repeat(4)begin @(negedge clk);if(!out_valid || {out_error,out_data}!==held || in_ready)$fatal(1,"ADD backpressure changed result");end
            out_ready=1;@(negedge clk);out_ready=0;checked=checked+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("COUNT=%d",count) || count>2048)$fatal(1,"missing ADD count");
        $readmemh("unit.mem",vectors,0,count-1);
        if(vectors[0][175:160]!==16'd2 || vectors[1][175:160]!==16'd0 || vectors[2][175:160]!==16'd30000)$fatal(1,"ADD anchors invalid");
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<count;n=n+1)begin send(n);finish(n);end
        for(phase=0;phase<2;phase=phase+1)begin
            send(0);repeat(phase)@(negedge clk);rst_n=0;repeat(2)@(negedge clk);rst_n=1;
            repeat(4)begin @(negedge clk);if(out_valid || !in_ready)$fatal(1,"stale ADD after reset");end
            send(0);finish(0);
        end
        $display("PASS add_int16 outputs=%0d reset_replays=2",checked);$finish;
    end
    initial begin #1000000;$fatal(1,"ADD unit timeout");end
endmodule
