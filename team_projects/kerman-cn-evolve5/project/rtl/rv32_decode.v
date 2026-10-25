`timescale 1ns/1ps
`include "rv32_defs.vh"
// Optional complete M extension. Zicsr/system legality is resolved in the core.
module rv32_decode #(parameter integer M_ENABLE=0) (
    input wire [31:0] insn,
    output wire [4:0] rs1, rs2, rd,
    output reg use_rs1, use_rs2, rd_write,
    output reg [31:0] imm,
    output reg [3:0] alu_op,
    output reg a_is_pc, b_is_imm,
    output reg is_load, is_store, is_branch, is_jal, is_jalr,
    output wire [2:0] funct3,
    output reg illegal, ecall, ebreak
);
    wire [6:0] opcode = insn[6:0];
    wire [6:0] funct7 = insn[31:25];
    assign rs1 = insn[19:15];
    assign rs2 = insn[24:20];
    assign rd = insn[11:7];
    assign funct3 = insn[14:12];
    always @* begin
        use_rs1 = 0; use_rs2 = 0; rd_write = 0;
        imm = 0; alu_op = `ALU_ADD; a_is_pc = 0; b_is_imm = 0;
        is_load = 0; is_store = 0; is_branch = 0;
        is_jal = 0; is_jalr = 0; illegal = 0; ecall = 0; ebreak = 0;
        case (opcode)
            7'h37: begin // LUI
                rd_write = 1; b_is_imm = 1; alu_op = `ALU_COPY;
                imm = {insn[31:12], 12'b0};
            end
            7'h17: begin // AUIPC
                rd_write = 1; a_is_pc = 1; b_is_imm = 1;
                imm = {insn[31:12], 12'b0};
            end
            7'h6f: begin // JAL
                rd_write = 1; is_jal = 1;
                imm = {{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
            end
            7'h67: begin // JALR
                rd_write = 1; use_rs1 = 1; is_jalr = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                if (funct3 != 0) illegal = 1;
            end
            7'h63: begin
                use_rs1 = 1; use_rs2 = 1; is_branch = 1;
                imm = {{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
                case (funct3)
                    3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h03: begin
                use_rs1 = 1; rd_write = 1; is_load = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                case (funct3)
                    3'd0,3'd1,3'd2,3'd4,3'd5: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h23: begin
                use_rs1 = 1; use_rs2 = 1; is_store = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:25],insn[11:7]};
                case (funct3)
                    3'd0,3'd1,3'd2: illegal = 0;
                    default: illegal = 1;
                endcase
            end
            7'h13: begin
                use_rs1 = 1; rd_write = 1; b_is_imm = 1;
                imm = {{20{insn[31]}},insn[31:20]};
                case (funct3)
                    3'd0: alu_op = `ALU_ADD;
                    3'd2: alu_op = `ALU_SLT;
                    3'd3: alu_op = `ALU_SLTU;
                    3'd4: alu_op = `ALU_XOR;
                    3'd6: alu_op = `ALU_OR;
                    3'd7: alu_op = `ALU_AND;
                    3'd1: begin
                        alu_op = `ALU_SLL;
                        if (funct7 != 0) illegal = 1;
                    end
                    3'd5: begin
                        alu_op = insn[30] ? `ALU_SRA : `ALU_SRL;
                        if (funct7 != 0 && funct7 != 7'h20) illegal = 1;
                    end
                endcase
            end
            7'h33: begin
                use_rs1 = 1; use_rs2 = 1; rd_write = 1;
                case (funct3)
                    3'd0: alu_op = insn[30] ? `ALU_SUB : `ALU_ADD;
                    3'd1: alu_op = `ALU_SLL;
                    3'd2: alu_op = `ALU_SLT;
                    3'd3: alu_op = `ALU_SLTU;
                    3'd4: alu_op = `ALU_XOR;
                    3'd5: alu_op = insn[30] ? `ALU_SRA : `ALU_SRL;
                    3'd6: alu_op = `ALU_OR;
                    3'd7: alu_op = `ALU_AND;
                endcase
                if (funct7 != 0 && !(funct7 == 7'h20 && (funct3 == 0 || funct3 == 5)) && !(M_ENABLE && funct7==7'h01))
                    illegal = 1;
            end
            7'h0f: begin
                // Single hart, uncached, strongly ordered, no posted stores.
                // FENCE needs no extra operation. rd/rs1/fm are ignored as
                // required for forward compatibility; FENCE.I is unsupported.
                if (funct3 != 0) illegal = 1;
            end
            7'h73: begin
                if (insn == 32'h00000073) ecall = 1;
                else if (insn == 32'h00100073) ebreak = 1;
                else illegal = 1;
            end
            default: illegal = 1;
        endcase
    end
endmodule
