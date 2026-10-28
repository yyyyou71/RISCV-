`timescale 1ns/1ps
// Two asynchronous read ports, one rising-edge write port. x0 is immutable.
// Same-cycle write-through is intentional and part of the ID/WB contract.
module rv32_regfile #(parameter integer DUAL_ENABLE=0) (
    input wire clk, rst,
    input wire [4:0] rs1, rs2,
    output wire [31:0] rdata1, rdata2,
    input wire we,
    input wire [4:0] rd,
    input wire [31:0] wdata,
    input wire [4:0] rs3,rs4,rd2,
    output wire [31:0] rdata3,rdata4,
    input wire we2,
    input wire [31:0] wdata2
);
    reg [31:0] regs [0:31];
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if(DUAL_ENABLE) begin
            for(i=1;i<32;i=i+1) begin
                if(we2 && rd2==i) regs[i]<=wdata2;
                else if(we && rd==i) regs[i]<=wdata;
            end
        end else if (we && rd != 0) regs[rd] <= wdata;
    end
    assign rdata1 = rs1 == 0 ? 32'b0 :
                    (DUAL_ENABLE && we2 && rd2==rs1 ? wdata2 : we && rd == rs1 ? wdata : regs[rs1]);
    assign rdata2 = rs2 == 0 ? 32'b0 :
                    (DUAL_ENABLE && we2 && rd2==rs2 ? wdata2 : we && rd == rs2 ? wdata : regs[rs2]);
    assign rdata3 = !DUAL_ENABLE || rs3==0 ? 32'b0 :
                    (we2 && rd2==rs3 ? wdata2 : we && rd==rs3 ? wdata : regs[rs3]);
    assign rdata4 = !DUAL_ENABLE || rs4==0 ? 32'b0 :
                    (we2 && rd2==rs4 ? wdata2 : we && rd==rs4 ? wdata : regs[rs4]);
endmodule
