`timescale 1ns/1ps
`default_nettype none

// 同时运行 0..5 级、同步/异步复位、静态加/减共 24 个实例。
// 每个实例的逐时刻期望值由 Python 任意精度整数和事务延迟队列生成。
module TB_multiply_adder;
    parameter integer A_WIDTH = 8, B_WIDTH = 8, A_SIGNED = 1, B_SIGNED = 1;
    localparam integer P_WIDTH = A_WIDTH+B_WIDTH+1;
    localparam integer STIM_WIDTH = 2*A_WIDTH+2*B_WIDTH+4;
    localparam integer CHECK_WIDTH = 24*P_WIDTH;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 0, ce = 0, addsub = 0;
    reg [A_WIDTH-1:0] a0 = 0, a1 = 0;
    reg [B_WIDTH-1:0] b0 = 0, b1 = 0;
    wire [CHECK_WIDTH-1:0] actual;
    genvar subtract_mode, async_mode, stages;
    generate
        for (subtract_mode = 0; subtract_mode < 2; subtract_mode = subtract_mode+1) begin : g_subtract
            for (async_mode = 0; async_mode < 2; async_mode = async_mode+1) begin : g_async
                for (stages = 0; stages <= 5; stages = stages+1) begin : g_stages
                    localparam integer LANE = (subtract_mode*2+async_mode)*6+stages;
                    multiply_adder #(
                        .A_WIDTH(A_WIDTH), .B_WIDTH(B_WIDTH), .A_SIGNED(A_SIGNED), .B_SIGNED(B_SIGNED),
                        .PIPE_STAGES(stages), .ASYNC_RESET(async_mode), .STATIC_SUBTRACT(subtract_mode)
                    ) dut (
                        .a0(a0), .a1(a1), .b0(b0), .b1(b1),
                        .clk(clk), .rst(rst), .ce(ce), .addsub(addsub),
                        .p(actual[LANE*P_WIDTH +: P_WIDTH])
                    );
                end
            end
        end
    endgenerate

    reg [STIM_WIDTH-1:0] stimuli [0:8191];
    reg [CHECK_WIDTH-1:0] before_edge [0:8191], after_edge [0:8191], after_pulse [0:8191];
    integer count, row, lane, checks = 0;
    task compare;
        input [CHECK_WIDTH-1:0] expected;
        input [127:0] phase;
        begin
            for (lane = 0; lane < 24; lane = lane+1) begin
                if (actual[lane*P_WIDTH +: P_WIDTH] !== expected[lane*P_WIDTH +: P_WIDTH])
                    $fatal(1, "phase=%s row=%0d sub=%0d async=%0d stages=%0d got=%h expected=%h",
                           phase, row, lane/12, (lane/6)%2, lane%6,
                           actual[lane*P_WIDTH +: P_WIDTH], expected[lane*P_WIDTH +: P_WIDTH]);
                checks = checks+1;
            end
        end
    endtask
    initial begin
        if (!$value$plusargs("ROWS=%d",count) || count < 2 || count > 8192)
            $fatal(1,"missing/invalid vector count");
        $readmemh("stimuli.mem",stimuli,0,count-1);
        $readmemh("before.mem",before_edge,0,count-1);
        $readmemh("after.mem",after_edge,0,count-1);
        $readmemh("pulse.mem",after_pulse,0,count-1);
        for (row = 0; row < count; row = row+1) begin
            @(negedge clk);
            rst = stimuli[row][0]; ce = stimuli[row][1]; addsub = stimuli[row][2];
            a0 = stimuli[row][4 +: A_WIDTH]; a1 = stimuli[row][4+A_WIDTH +: A_WIDTH];
            b0 = stimuli[row][4+2*A_WIDTH +: B_WIDTH];
            b1 = stimuli[row][4+2*A_WIDTH+B_WIDTH +: B_WIDTH];
            // 第一拍之前同步复位实例尚未复位，不比较未知的上电状态。
            #1; if (row > 0) compare(before_edge[row], "before edge");
            @(posedge clk); #1; compare(after_edge[row], "after edge");
            // 在两个上升沿之间打一段复位脉冲：只能影响异步复位实例。
            if (stimuli[row][3]) begin
                #1; rst = 1;
                #1; compare(after_pulse[row], "reset pulse");
                #1; rst = 0;
            end else compare(after_pulse[row], "no pulse");
        end
        $display("PASS multiply_adder A=%0d/%0d B=%0d/%0d rows=%0d instances=24 checks=%0d",
                 A_WIDTH,A_SIGNED,B_WIDTH,B_SIGNED,count,checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"multiply_adder regression timeout");
    end
endmodule

`default_nettype wire
