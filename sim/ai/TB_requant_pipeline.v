`timescale 1ns/1ps
module TB_requant_pipeline;
    reg clk=0,rst_n=0,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    wire in_ready,out_valid,out_error,out_clamped;
    wire gold_ready,gold_valid,gold_error,gold_clamped;
    wire [15:0] out_data,gold_data;
    reg signed [63:0] in_sum0=0,in_sum1=0;
    reg group1_enable=0,relu=0;
    reg [31:0] mult_m0=0,mult_m1=0,mult_y=0,shift_m0=0,shift_m1=0,shift_y=0;
    reg signed [31:0] bias_q13=0;
    requant_q13 dut(.*);
    requant_q13_gold gold(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(gold_ready),
      .in_sum0(in_sum0),.in_sum1(in_sum1),.group1_enable(group1_enable),.mult_m0(mult_m0),.shift_m0(shift_m0),
      .mult_m1(mult_m1),.shift_m1(shift_m1),.bias_q13(bias_q13),.mult_y(mult_y),.shift_y(shift_y),.relu(relu),
      .out_valid(gold_valid),.out_ready(out_ready),.out_data(gold_data),.out_error(gold_error),.out_clamped(gold_clamped));
    integer i;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(i=0;i<512;i=i+1)begin
            wait(in_ready && gold_ready);@(negedge clk);
            in_sum0={$urandom,$urandom};in_sum1={$urandom,$urandom};
            mult_m0=$urandom&32'h7fffffff;mult_m1=$urandom&32'h7fffffff;mult_y=$urandom&32'h7fffffff;
            shift_m0=$urandom%96;shift_m1=$urandom%96;shift_y=$urandom%96;
            bias_q13=$urandom;group1_enable=i%2;relu=(i/2)%2;
            if(i%4==0)begin in_sum0=$signed($urandom)>>8;in_sum1=$signed($urandom)>>8;shift_m0=31;shift_m1=29;shift_y=24;end
            if(i%16==0)begin in_sum0=64'h8000000000000000;in_sum1=64'h7fffffffffffffff;shift_m0=0;shift_m1=0;end
            if(i%17==0)mult_m0=32'hffffffff;
            if(i%19==0)shift_y=96;
            in_valid=1;@(negedge clk);in_valid=0;
            wait(out_valid && gold_valid);repeat(2)@(negedge clk);
            if({out_error,out_clamped,out_data}!=={gold_error,gold_clamped,gold_data})
              $fatal(1,"quant mismatch case=%0d new=%h gold=%h",i,{out_error,out_clamped,out_data},{gold_error,gold_clamped,gold_data});
            out_ready=1;@(negedge clk);out_ready=0;
        end
        $display("PASS quantization: 512 exact comparisons with pre-P4 implementation + backpressure");$finish;
    end
    initial begin #1000000;$fatal(1,"quantization timeout");end
endmodule
