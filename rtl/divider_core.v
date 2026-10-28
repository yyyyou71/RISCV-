// 32 位无符号恢复余数除法器，每拍生成一位商，不使用 /、% 或乘法器。
// start 在空闲时采样两路输入，随后固定迭代 32 拍；done 仅有效一拍。
// quotient/remainder 在 done 有效时可用，busy 期间不接受新请求。
module divider_core(
    input clk,
    input rst_n,
    input start,
    input [31:0] dividend,
    input [31:0] divisor,
    output reg busy,
    output reg done,
    output reg [31:0] quotient,
    output reg [31:0] remainder
);
    reg [31:0] divisor_reg;
    reg [5:0] iteration;

    // 把被除数的下一位移入余数，再试减除数。正常迭代中余数小于除数，
    // 因此差的第 32 位可以判断是否借位，省去另一组独立比较器。
    wire [32:0] shifted_remainder = {remainder, quotient[31]};
    wire [32:0] difference = shifted_remainder - {1'b0, divisor_reg};
    wire subtract_ok = !difference[32];
    wire [31:0] next_remainder = subtract_ok ? difference[31:0] : shifted_remainder[31:0];
    wire [31:0] next_quotient = {quotient[30:0], subtract_ok};

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0;
            done <= 0;
            quotient <= 0;
            remainder <= 0;
            divisor_reg <= 0;
            iteration <= 0;
        end else begin
            done <= 0;
            if (busy) begin
                quotient <= next_quotient;
                remainder <= next_remainder;
                if (iteration == 6'd31) begin
                    busy <= 0;
                    done <= 1;
                end else begin
                    iteration <= iteration + 1'b1;
                end
            end else if (start) begin
                busy <= 1;
                quotient <= dividend;
                remainder <= 0;
                divisor_reg <= divisor;
                iteration <= 0;
            end
        end
    end
    // 除数为 0 时，每次试减均成功，商自然成为全 1、余数成为原被除数，
    // 与 RISC-V 无符号除零规则一致，不需要额外的异常处理路径。
endmodule
