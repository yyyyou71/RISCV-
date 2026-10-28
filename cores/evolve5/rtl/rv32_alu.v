`timescale 1ns/1ps
`include "rv32_defs.vh"
module rv32_alu (
    input wire [31:0] a, b,
    input wire [3:0] op,
    output reg [31:0] result
);
    always @* begin
        case (op)
            `ALU_ADD:  result = a + b;
            `ALU_SUB:  result = a - b;
            `ALU_SLL:  result = a << b[4:0];
            `ALU_SLT:  result = {31'b0, $signed(a) < $signed(b)};
            `ALU_SLTU: result = {31'b0, a < b};
            `ALU_XOR:  result = a ^ b;
            `ALU_SRL:  result = a >> b[4:0];
            `ALU_SRA:  result = $signed(a) >>> b[4:0];
            `ALU_OR:   result = a | b;
            `ALU_AND:  result = a & b;
            `ALU_COPY: result = b;
            default:  result = 32'b0;
        endcase
    end
endmodule
