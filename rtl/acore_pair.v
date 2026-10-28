module acore_pair (
    input [31:0] first,
    input [31:0] second,
    input available,
    output pair
);
    function simple;
        input [31:0] insn;
        begin
            case (insn[6:0])
                7'h37, 7'h17: simple = 1'b1;
                7'h13: case (insn[14:12])
                    3'h1: simple = insn[31:25] == 7'h00;
                    3'h5: simple = insn[31:25] == 7'h00 || insn[31:25] == 7'h20;
                    default: simple = 1'b1;
                endcase
                7'h33: simple = insn[31:25] == 7'h00 ||
                    (insn[31:25] == 7'h20 && (insn[14:12] == 0 || insn[14:12] == 5));
                default: simple = 1'b0;
            endcase
        end
    endfunction
    wire uses_rs1_b = second[6:0] == 7'h13 || second[6:0] == 7'h33;
    wire uses_rs2_b = second[6:0] == 7'h33;
    wire [4:0] rd_a = first[11:7];
    wire raw = rd_a != 0 && ((uses_rs1_b && rd_a == second[19:15]) ||
                                      (uses_rs2_b && rd_a == second[24:20]));
    wire waw = rd_a != 0 && rd_a == second[11:7];
    assign pair = available && simple(first) && simple(second) && !raw && !waw;
endmodule
