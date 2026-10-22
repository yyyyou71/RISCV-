`timescale 1ns/1ps

// 同时检查手册支持的 1～5 级延迟，所有比较都避开非阻塞赋值调度竞争。
module TB_multiplier;
    wire [5:1] done;
    genvar stage;
    generate
        for (stage = 1; stage <= 5; stage = stage+1) begin : g_check
            multiplier_checker #(.STAGES(stage)) u_check (.done(done[stage]));
        end
    endgenerate
    initial begin
        wait (&done);
        $display("PASS: multiplier IP and execution unit, pipeline stages 1..5");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Multiplier test timeout");
    end
endmodule

module multiplier_checker #(
    parameter integer STAGES = 3
)(
    output reg done = 0
);
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg ce = 0;
    reg signed [32:0] a = 0;
    reg signed [32:0] b = 0;
    wire signed [65:0] p;
    reg signed [65:0] expected_pipe [0:STAGES-1];
    reg signed [65:0] previous_p;
    integer cycle;
    integer lane;
    integer i;
    integer j;
    integer op;
    reg [31:0] edges [0:8];
    reg [31:0] random_a;
    reg [31:0] random_b;

    multiplier_core #(.PIPE_STAGES(STAGES)) ip (
        .clk(clk), .rst(rst), .ce(ce), .a(a), .b(b), .p(p)
    );

    reg rst_n = 0;
    reg start = 0;
    reg [1:0] operation = 0;
    reg [31:0] rs1 = 0;
    reg [31:0] rs2 = 0;
    wire busy;
    wire ready;
    wire [31:0] result;
    multiply_unit #(.PIPE_STAGES(STAGES)) unit_under_test (
        .clk(clk), .rst_n(rst_n), .start(start), .operation(operation),
        .rs1(rs1), .rs2(rs2), .busy(busy), .ready(ready), .result(result)
    );

    // 用 64 位带符号/无符号计算建立参考，与被测的 33 位扩展路径独立。
    function [31:0] reference_result;
        input [31:0] lhs;
        input [31:0] rhs;
        input [1:0] kind;
        reg signed [63:0] signed_lhs;
        reg signed [63:0] signed_rhs;
        reg [63:0] full_product;
        begin
            signed_lhs = {{32{lhs[31]}}, lhs};
            signed_rhs = {{32{rhs[31]}}, rhs};
            case (kind)
                0: full_product = {32'b0, lhs} * {32'b0, rhs};
                1: full_product = signed_lhs * signed_rhs;
                2: full_product = signed_lhs * $signed({32'b0, rhs});
                3: full_product = {32'b0, lhs} * {32'b0, rhs};
            endcase
            reference_result = (kind == 0) ? full_product[31:0] : full_product[63:32];
        end
    endfunction

    task check_operation;
        input [31:0] lhs;
        input [31:0] rhs;
        input [1:0] kind;
        integer edge_index;
        reg [31:0] want;
        begin
            want = reference_result(lhs, rhs, kind);
            @(negedge clk);
            start = 1;
            operation = kind;
            rs1 = lhs;
            rs2 = rhs;
            for (edge_index = 1; edge_index <= STAGES; edge_index = edge_index+1) begin
                @(posedge clk);
                #1;
                if (!busy || ready !== (edge_index == STAGES))
                    $fatal(1, "STAGES=%0d incorrect ready at edge %0d", STAGES, edge_index);
                if (edge_index < STAGES) begin
                    // 输入和操作类型随后变化，且 busy 期间重复 start，
                    // 均不得改变第一次请求的计算结果或延迟。
                    @(negedge clk);
                    rs1 = ~lhs;
                    rs2 = ~rhs;
                    operation = ~kind;
                end
            end
            if (result !== want)
                $fatal(1, "STAGES=%0d op=%0d a=%h b=%h got=%h expected=%h",
                       STAGES, kind, lhs, rhs, result, want);
            @(negedge clk);
            start = 0;
            @(posedge clk);
            #1;
            if (busy || ready)
                $fatal(1, "STAGES=%0d completed request repeated", STAGES);
        end
    endtask

    initial begin
        // 原始 IP 接口：每拍随机输入、ce 断续、流水中复位以及复位优先于 ce。
        for (cycle = 0; cycle < 400; cycle = cycle+1) begin
            @(negedge clk);
            previous_p = p;
            a = {$urandom_range(0, 1) != 0, $urandom};
            b = {$urandom_range(0, 1) != 0, $urandom};
            rst = (cycle < 2 || cycle == 107 || cycle == 213);
            ce = ($urandom_range(0, 3) != 0);
            #1;
            if (cycle != 0 && p !== previous_p)
                $fatal(1, "STAGES=%0d IP changed without rising edge", STAGES);
            @(posedge clk);
            if (rst) begin
                for (lane = 0; lane < STAGES; lane = lane+1)
                    expected_pipe[lane] = 0;
            end else if (ce) begin
                for (lane = STAGES-1; lane > 0; lane = lane-1)
                    expected_pipe[lane] = expected_pipe[lane-1];
                expected_pipe[0] = a * b;
            end
            #1;
            if (p !== expected_pipe[STAGES-1])
                $fatal(1, "STAGES=%0d IP latency/ce/reset mismatch, cycle %0d", STAGES, cycle);
        end

        @(negedge clk);
        rst_n = 1;
        edges[0] = 0;
        edges[1] = 1;
        edges[2] = 2;
        edges[3] = 32'hffffffff;
        edges[4] = 32'h80000000;
        edges[5] = 32'h7fffffff;
        edges[6] = 32'h80000001;
        edges[7] = 32'haaaaaaaa;
        edges[8] = 32'h55555555;
        for (i = 0; i < 9; i = i+1)
            for (j = 0; j < 9; j = j+1)
                for (op = 0; op < 4; op = op+1)
                    check_operation(edges[i], edges[j], op[1:0]);
        for (i = 0; i < 100; i = i+1) begin
            random_a = $urandom;
            random_b = $urandom;
            for (op = 0; op < 4; op = op+1)
                check_operation(random_a, random_b, op[1:0]);
        end

        // 复位中止正在执行的乘法，释放后不得出现旧结果的 ready。
        @(negedge clk);
        start = 1;
        rs1 = 32'h80000000;
        rs2 = 32'hffffffff;
        @(posedge clk);
        @(negedge clk);
        start = 0;
        rst_n = 0;
        @(posedge clk);
        #1;
        if (busy || ready) $fatal(1, "Reset did not abort multiplication");
        @(negedge clk);
        rst_n = 1;
        repeat (STAGES+1) begin
            @(posedge clk);
            #1;
            if (busy || ready) $fatal(1, "Stale multiplication after reset");
        end
        check_operation(32'h80000000, 32'hffffffff, 2'b10);
        $display("PASS: STAGES=%0d, 400 IP cycles, 725 arithmetic/reset requests", STAGES);
        done = 1;
    end
endmodule
