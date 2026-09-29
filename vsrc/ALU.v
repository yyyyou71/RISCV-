module ALU(
    input clk,

    input [3:0]opcode,
    input [31:0]oprand1,
    input [31:0]oprand2,
    input en,

    input flush,
    input valid_in,
    input stall,

    output [31:0]out,
    output reg valid_out
);
    // 操作码参数定义
    localparam OP_ADD  = 4'b0000;
    localparam OP_SUB  = 4'b0001;
    localparam OP_AND  = 4'b0010;
    localparam OP_OR   = 4'b0011;
    localparam OP_XOR  = 4'b0100;
    localparam OP_SLL  = 4'b0101;
    localparam OP_SRL  = 4'b0110;
    localparam OP_SRA  = 4'b0111;
    localparam OP_SLT  = 4'b1000;
    localparam OP_SLTU = 4'b1001;
    localparam OP_EQ   = 4'b1010;


    reg [31:0]out_reg;
    assign out = out_reg;

    always @(posedge clk) begin
        if (!en | stall) begin
            out_reg <= out_reg;
        end
        else begin
            case (opcode)
                OP_ADD : out_reg <= oprand1 + oprand2;                       // add
                OP_SUB : out_reg <= oprand1 - oprand2;                       // sub
                OP_AND : out_reg <= oprand1 & oprand2;                       // and
                OP_OR  : out_reg <= oprand1 | oprand2;                       // or
                OP_XOR : out_reg <= oprand1 ^ oprand2;                       // xor
                OP_SLL : out_reg <= oprand1 << oprand2[4:0];                 // sll
                OP_SRL : out_reg <= oprand1 >> oprand2[4:0];                 // srl
                OP_SRA : out_reg <= $signed(oprand1) >>> oprand2[4:0];       // sra

                // slt, 有符号比较
                OP_SLT : out_reg <= ({~oprand1[31], oprand1[30:0]} < 
                                    {~oprand2[31], oprand2[30:0]}) ? 32'b1 : 32'b0;

                OP_SLTU: out_reg <= (oprand1 < oprand2) ? 32'b1 : 32'b0;     // sltu，无符号比较
                OP_EQ  : out_reg <= (oprand1 == oprand2) ? 32'b1 : 32'b0;    // eq，相等为1

                default: out_reg <= out_reg;
            endcase
        end
    end


    // 是否载入流水线标志位
    always @(posedge clk) begin
        if(flush)
            valid_out <= 0;
        else if(stall)
            valid_out <= valid_out;
        else
            valid_out <= valid_in;
    end
endmodule
