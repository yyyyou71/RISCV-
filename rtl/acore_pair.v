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
    wire load_b = second[6:0] == 7'h03 && (second[14:12] == 0 || second[14:12] == 1 ||
                  second[14:12] == 2 || second[14:12] == 4 || second[14:12] == 5);
    wire store_b = second[6:0] == 7'h23 && second[14:12] <= 2;
    wire branch_b = second[6:0] == 7'h63 && second[14:12] != 2 && second[14:12] != 3;
    wire jalr_b = second[6:0] == 7'h67 && second[14:12] == 0;
    wire jump_b = second[6:0] == 7'h6f || jalr_b;
    wire uses_rs1_b = second[6:0] == 7'h13 || second[6:0] == 7'h33 || load_b || store_b || branch_b || jalr_b;
    wire uses_rs2_b = second[6:0] == 7'h33 || store_b || branch_b;
    wire load_a = first[6:0] == 7'h03 && (first[14:12] == 0 || first[14:12] == 1 ||
                  first[14:12] == 2 || first[14:12] == 4 || first[14:12] == 5);
    wire store_a = first[6:0] == 7'h23 && first[14:12] <= 2;
    wire [4:0] rd_a = store_a ? 5'd0 : first[11:7];
    wire raw = rd_a != 0 && ((uses_rs1_b && rd_a == second[19:15]) ||
                                      (uses_rs2_b && rd_a == second[24:20]));
    wire waw = !store_b && !branch_b && rd_a != 0 && rd_a == second[11:7];
    assign pair = available && !raw && !waw &&
                  (((simple(first) || load_a || store_a) && simple(second)) ||
                   (simple(first) && (load_b || store_b || branch_b || jump_b)));
endmodule
