`timescale 1ns/1ps
module TB_requant_int8;
    reg clk=0,rst_n=0,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    reg signed [63:0] in_sum=0;
    reg [31:0] multiplier=0,shift=0;
    reg relu=0;
    wire in_ready,out_valid,out_error;
    wire [7:0] out_data;
    requant_int8 dut(.*);
    reg [191:0] vectors[0:16383];
    integer count,n,k,checked=0;
    task reset_all;
        begin
            @(negedge clk);rst_n=0;in_valid=0;out_ready=0;
            repeat(3)@(negedge clk);rst_n=1;
            @(negedge clk);
            if(out_valid || !in_ready)$fatal(1,"quant reset failed");
        end
    endtask
    initial begin
        if(!$value$plusargs("COUNT=%d",count))$fatal(1,"missing vectors");
        $readmemh("vectors.mem",vectors,0,count-1);
        reset_all;
        for(n=0;n<count;n=n+1)begin
            @(negedge clk);
            in_sum=vectors[n][63:0];multiplier=vectors[n][95:64];shift=vectors[n][127:96];relu=vectors[n][128];in_valid=1;
            @(posedge clk);if(!in_ready)$fatal(1,"quant unexpectedly busy");
            @(negedge clk);in_valid=0;
            if(n==50)begin
                // 乘积已入寄存器时复位，旧结果不能随后出现。
                reset_all;
                in_sum=vectors[n][63:0];multiplier=vectors[n][95:64];shift=vectors[n][127:96];relu=vectors[n][128];in_valid=1;
                @(negedge clk);in_valid=0;
            end
            in_sum=64'hdeadbeef;multiplier=32'hffffffff;shift=96;relu=~relu;
            wait(out_valid);
            for(k=0;k<(n%5)+1;k=k+1)begin
                @(negedge clk);
                if(!out_valid || in_ready || out_data!==vectors[n][143:136] || out_error!==vectors[n][144])
                    $fatal(1,"quant mismatch/stall n=%0d got=%h err=%b expected=%h",n,out_data,out_error,vectors[n]);
            end
            out_ready=1;@(negedge clk);out_ready=0;
            if(out_valid || !in_ready)$fatal(1,"quant completion failed");
            checked=checked+1;
        end
        $display("PASS requant vectors=%0d reset_inflight=1",checked);$finish;
    end
    initial begin #2000000;$fatal(1,"quant timeout");end
endmodule
