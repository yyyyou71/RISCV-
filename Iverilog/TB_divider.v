`timescale 1ns/1ps

// 同时检查无符号除法核心和带符号的 RISC-V 除法执行单元。
module TB_divider;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg start = 0;
    reg [1:0] operation = 0;
    reg [31:0] rs1 = 0;
    reg [31:0] rs2 = 0;
    wire busy;
    wire ready;
    wire [31:0] result;
    wire core_busy;
    wire core_done;
    wire [31:0] quotient;
    wire [31:0] remainder;
    integer checks = 0;
    integer i;
    integer j;
    integer op;
    reg [31:0] edges [0:8];
    reg [31:0] random_a;
    reg [31:0] random_b;

    divide_unit dut (
        .clk(clk), .rst_n(rst_n), .start(start), .operation(operation),
        .rs1(rs1), .rs2(rs2), .busy(busy), .ready(ready), .result(result)
    );
    divider_core unsigned_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .dividend(rs1), .divisor(rs2),
        .busy(core_busy), .done(core_done), .quotient(quotient), .remainder(remainder)
    );

    // 参考运算只存在于测试台，不会被综合进除法器。
    function [31:0] reference_result;
        input [31:0] lhs;
        input [31:0] rhs;
        input [1:0] kind;
        reg signed [63:0] signed_lhs;
        reg signed [63:0] signed_rhs;
        reg [63:0] value;
        begin
            signed_lhs = {{32{lhs[31]}}, lhs};
            signed_rhs = {{32{rhs[31]}}, rhs};
            if (rhs == 0)
                reference_result = kind[1] ? lhs : 32'hffffffff;
            else if (!kind[0]) begin
                value = kind[1] ? (signed_lhs % signed_rhs) : (signed_lhs / signed_rhs);
                reference_result = value[31:0];
            end else begin
                value = kind[1] ? ({32'b0, lhs} % {32'b0, rhs}) : ({32'b0, lhs} / {32'b0, rhs});
                reference_result = value[31:0];
            end
        end
    endfunction

    task check_operation;
        input [31:0] lhs;
        input [31:0] rhs;
        input [1:0] kind;
        integer iteration;
        reg [31:0] want;
        reg [31:0] want_q;
        reg [31:0] want_r;
        begin
            want = reference_result(lhs, rhs, kind);
            want_q = (rhs == 0) ? 32'hffffffff : (lhs / rhs);
            want_r = (rhs == 0) ? lhs : (lhs % rhs);
            @(negedge clk);
            start = 1;
            rs1 = lhs;
            rs2 = rhs;
            operation = kind;
            @(posedge clk);
            #1;
            if (!busy || ready || !core_busy || core_done)
                $fatal(1, "Division did not start correctly");
            for (iteration = 1; iteration <= 32; iteration = iteration+1) begin
                // 运算中改变输入，并重复拉高 start，验证操作数与功能已锁存。
                @(negedge clk);
                rs1 = ~lhs;
                rs2 = ~rhs;
                operation = ~kind;
                @(posedge clk);
                #1;
                if (!busy || ready !== (iteration == 32) || core_done !== ready)
                    $fatal(1, "Incorrect ready at division iteration %0d", iteration);
            end
            if (result !== want || quotient !== want_q || remainder !== want_r)
                $fatal(1, "op=%0d a=%h b=%h got=%h want=%h unsigned q=%h/%h r=%h/%h",
                       kind, lhs, rhs, result, want, quotient, want_q, remainder, want_r);
            @(negedge clk);
            start = 0;
            @(posedge clk);
            #1;
            if (busy || ready || core_busy || core_done)
                $fatal(1, "Completed division repeated");
            checks = checks + 1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        edges[0] = 0;
        edges[1] = 1;
        edges[2] = 2;
        edges[3] = 3;
        edges[4] = 32'hffffffff;
        edges[5] = 32'h80000000;
        edges[6] = 32'h7fffffff;
        edges[7] = 32'h80000001;
        edges[8] = 32'hfffffffd;
        for (i = 0; i < 9; i = i+1)
            for (j = 0; j < 9; j = j+1)
                for (op = 0; op < 4; op = op+1)
                    check_operation(edges[i], edges[j], op[1:0]);
        for (i = 0; i < 500; i = i+1) begin
            random_a = $urandom;
            random_b = $urandom;
            for (op = 0; op < 4; op = op+1)
                check_operation(random_a, random_b, op[1:0]);
        end

        // 同步复位中止运算，随后等待完整延迟，不能再收到旧请求的 ready。
        @(negedge clk);
        start = 1;
        rs1 = 12345;
        rs2 = 7;
        operation = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 0;
        start = 0;
        @(posedge clk);
        #1;
        if (busy || ready || core_busy || core_done)
            $fatal(1, "Reset did not abort division");
        @(negedge clk);
        rst_n = 1;
        repeat (35) begin
            @(posedge clk);
            #1;
            if (busy || ready || core_busy || core_done)
                $fatal(1, "Stale result after reset");
        end
        check_operation(32'h80000000, 32'hffffffff, 0);
        $display("PASS: divider core and execution unit, %0d requests plus reset abort", checks);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Division test timeout");
    end
endmodule
