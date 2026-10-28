// RISC-V 除法执行单元：先取绝对值，再执行无符号除法，最后修正符号。
// operation 依次对应 DIV、DIVU、REM、REMU，即 funct3[1:0]。
// 从启动到 ready 共 33 个上升沿，处理器在第 34 个沿接收结果。
module divide_unit(
    input clk,
    input rst_n,
    input start,
    input [1:0] operation,
    input [31:0] rs1,
    input [31:0] rs2,
    output busy,
    output ready,
    output [31:0] result
);
    wire signed_operation = !operation[0];
    wire [31:0] magnitude_a = (signed_operation && rs1[31]) ? (~rs1 + 32'd1) : rs1;
    wire [31:0] magnitude_b = (signed_operation && rs2[31]) ? (~rs2 + 32'd1) : rs2;
    wire core_busy;
    wire core_done;
    wire [31:0] quotient;
    wire [31:0] remainder;
    wire accept = start && !busy;
    reg select_remainder;
    reg negate_quotient;
    reg negate_remainder;

    // 完成拍也保持 busy，避免旧指令仍在 EX 时重复启动。
    assign busy = core_busy || core_done;
    assign ready = core_done;
    wire [31:0] signed_quotient = negate_quotient ? (~quotient + 32'd1) : quotient;
    wire [31:0] signed_remainder = negate_remainder ? (~remainder + 32'd1) : remainder;
    assign result = select_remainder ? signed_remainder : signed_quotient;

    divider_core u_divider_core (
        .clk(clk), .rst_n(rst_n), .start(accept),
        .dividend(magnitude_a), .divisor(magnitude_b),
        .busy(core_busy), .done(core_done), .quotient(quotient), .remainder(remainder)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            select_remainder <= 0;
            negate_quotient <= 0;
            negate_remainder <= 0;
        end else if (accept) begin
            select_remainder <= operation[1];
            // 除零商必须为全 1，不允许再按被除数的符号取负。
            negate_quotient <= signed_operation && (rs1[31] ^ rs2[31]) && (rs2 != 0);
            negate_remainder <= signed_operation && rs1[31];
        end
    end
    // INT_MIN / -1 的无符号商为 0x80000000，符号相同无需取负，
    // 自然得到规范规定的溢出商 INT_MIN 和余数 0。
endmodule
