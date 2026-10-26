`timescale 1ns/1ps
module TB_requant_q13;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg in_valid=0,out_ready=0,group1_enable=0,relu=0;
    reg signed [63:0] in_sum0=0,in_sum1=0;
    reg signed [31:0] bias_q13=0;
    reg [31:0] mult_m0=0,shift_m0=0,mult_m1=0,shift_m1=0,mult_y=0,shift_y=0;
    wire in_ready,out_valid,out_error,out_clamped;
    wire [15:0] out_data;
    requant_q13 dut(.*);
    reg [447:0] vectors[0:4095];
    integer count,index,checked=0,phase;
    reg [17:0] held;
    task send;
        input integer n;
        begin
            @(negedge clk);
            in_sum0=vectors[n][63:0];in_sum1=vectors[n][127:64];group1_enable=vectors[n][128];
            mult_m0=vectors[n][191:160];shift_m0=vectors[n][223:192];
            mult_m1=vectors[n][255:224];shift_m1=vectors[n][287:256];
            bias_q13=vectors[n][319:288];mult_y=vectors[n][351:320];
            shift_y=vectors[n][383:352];relu=vectors[n][384];in_valid=1;
            if(!in_ready)$fatal(1,"quant not ready");
            @(negedge clk);in_valid=0;
            in_sum0=64'hbad;in_sum1=64'hbad;bias_q13=32'hbad;mult_m0=32'hffffffff;
            shift_m0=32'hffffffff;mult_m1=32'hffffffff;shift_m1=32'hffffffff;
            mult_y=32'hffffffff;shift_y=32'hffffffff;relu=~relu;group1_enable=~group1_enable;
        end
    endtask
    task finish;
        input integer n;
        begin
            wait(out_valid);@(negedge clk);
            if({out_clamped,out_error,out_data}!==vectors[n][433:416])
                $fatal(1,"Q13 mismatch index=%0d got=%h expected=%h",n,{out_clamped,out_error,out_data},vectors[n][433:416]);
            held={out_clamped,out_error,out_data};
            repeat(3) begin
                @(negedge clk);
                if(!out_valid || {out_clamped,out_error,out_data}!==held || in_ready)
                    $fatal(1,"quant changed under backpressure");
            end
            out_ready=1;@(negedge clk);out_ready=0;
            if(out_valid || !in_ready)$fatal(1,"quant result not consumed");
            checked=checked+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("COUNT=%d",count) || count>4096)$fatal(1,"bad count");
        $readmemh("quant.mem",vectors,0,count-1);
        repeat(3)@(negedge clk);rst_n=1;
        // 这些锚点不用软件结果来解释：RHU(-0.5)=0，两组各 +0.5 相加为 2。
        if(vectors[count-10][431:416]!==16'd1 || vectors[count-9][431:416]!==16'd0 ||
           vectors[count-8][431:416]!==16'd2)$fatal(1,"C quant anchor invalid");
        for(index=0;index<count;index=index+1) begin send(index);finish(index);end
        // 各乘积级以及输出反压期间复位，旧结果不得泄露。
        for(phase=0;phase<3;phase=phase+1)begin
            send(0);repeat(phase)@(negedge clk);rst_n=0;
            repeat(2)@(negedge clk);rst_n=1;
            repeat(5)begin @(negedge clk);if(out_valid || !in_ready)$fatal(1,"stale quant after reset");end
            send(count-10);finish(count-10);
        end
        $display("PASS requant_q13 vectors=%0d reset_replays=3",checked);$finish;
    end
    initial begin #1000000;$fatal(1,"Q13 timeout");end
endmodule
