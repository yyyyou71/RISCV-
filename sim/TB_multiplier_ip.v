`timescale 1ns/1ps
module TB_multiplier_ip;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 0;
    reg rst = 1;
    reg ce = 0;
    reg signed [32:0] operand_a = 0;
    reg signed [32:0] operand_b = 0;
    wire signed [65:0] product;
    reg signed [65:0] expected [0:2];
    reg signed [32:0] edges [0:5];
    integer left_index;
    integer right_index;
    integer sample_index;
    integer operation_index;
    integer checks = 0;
    reg start = 0;
    reg [1:0] operation = 0;
    reg [31:0] rs1 = 0;
    reg [31:0] rs2 = 0;
    wire busy;
    wire ready;
    wire [31:0] result;
    reg signed [65:0] reference_product;
    reg signed [32:0] extended_a;
    reg signed [32:0] extended_b;
    always #20 clk = ~clk;

    multiplier_core ip (.clk(clk), .rst(rst), .ce(ce), .a(operand_a), .b(operand_b), .p(product));
    multiply_unit unit_under_test (.clk(clk), .rst_n(!rst), .start(start), .operation(operation),
                                  .rs1(rs1), .rs2(rs2), .busy(busy), .ready(ready), .result(result));

    task advance;
        input reset_value;
        input enable_value;
        input signed [32:0] value_a;
        input signed [32:0] value_b;
        begin
            @(negedge clk);
            rst = reset_value;
            ce = enable_value;
            operand_a = value_a;
            operand_b = value_b;
            @(posedge clk);
            if (reset_value) begin
                expected[0] = 0;
                expected[1] = 0;
                expected[2] = 0;
            end else if (enable_value) begin
                expected[2] = expected[1];
                expected[1] = expected[0];
                expected[0] = value_a * value_b;
            end
            #1;
            if (product !== expected[2])
                $fatal(1, "Vendor multiplier latency/arithmetic/reset/CE mismatch: %h != %h", product, expected[2]);
            checks = checks + 1;
        end
    endtask

    initial begin
        edges[0] = 0;
        edges[1] = 1;
        edges[2] = -1;
        edges[3] = 33'h100000000;
        edges[4] = 33'h0ffffffff;
        edges[5] = 33'h080000000;
        advance(1, 0, 0, 0);
        for (left_index = 0; left_index < 6; left_index = left_index + 1)
            for (right_index = 0; right_index < 6; right_index = right_index + 1) begin
                advance(0, 1, edges[left_index], edges[right_index]);
                advance(0, 0, 33'd9, -33'd7);
            end
        for (sample_index = 0; sample_index < 160; sample_index = sample_index + 1)
            advance(sample_index == 63, sample_index % 4 != 0, {$random, $random}, {$random, $random});
        repeat (3) advance(0, 1, 0, 0);
        advance(1, 0, 0, 0);
        @(negedge clk);
        rst = 0;
        for (operation_index = 0; operation_index < 4; operation_index = operation_index + 1)
            for (sample_index = 0; sample_index < 40; sample_index = sample_index + 1) begin
                @(negedge clk);
                rs1 = $random;
                rs2 = $random;
                operation = operation_index[1:0];
                extended_a = {(operation == 1 || operation == 2) && rs1[31], rs1};
                extended_b = {operation == 1 && rs2[31], rs2};
                reference_product = extended_a * extended_b;
                start = 1;
                @(negedge clk);
                start = 0;
                wait (ready);
                #1;
                if (result !== (operation == 0 ? reference_product[31:0] : reference_product[63:32]))
                    $fatal(1, "MUL/MULH/MULHSU/MULHU mismatch");
                wait (!busy);
                checks = checks + 1;
            end
        $display("PASS: official multiplier and MUL/MULH/MULHSU/MULHU, %0d checks", checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Multiplier test timed out");
    end
endmodule
