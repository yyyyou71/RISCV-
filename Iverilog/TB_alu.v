module TB_alu();
    // ★ 所有 reg 都要给初值：没初始化的 reg 是 X，会把后面的判断全部污染
    reg clk = 1'b0;
    reg en = 1'b1;
    reg [3:0]opcode = 4'b0;
    reg [31:0]oprand1 = 32'b0;
    reg [31:0]oprand2 = 32'b0;
    reg flush = 1'b0;
    reg valid_in = 1'b0;
    reg stall = 1'b0;
    wire [31:0]out;
    wire [31:0]out_comb;
    wire valid_out;

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

    integer checks = 0;     // ★ 必须初始化：integer 没赋值是 X，X+1 还是 X
    integer errors = 0;


    ALU u_ALU(
        .clk       (clk       ),
        .opcode    (opcode    ),
        .oprand1   (oprand1   ),
        .oprand2   (oprand2   ),
        .en        (en        ),
        .flush     (flush     ),
        .valid_in  (valid_in  ),
        .stall     (stall     ),
        .out       (out       ),
        .out_comb  (out_comb  ),
        .valid_out (valid_out )
    );

    // 组合电路测试用不到时钟：out_comb 只跟 opcode/操作数有关。
    // 真要测寄存版 out 才需要打时钟。这里保持 clk = 0 即可。
    // always #10 clk = ~clk;

    task exam_comb;
        input [255:0]name;
        input [3:0]opcode_in;
        input [31:0]oprand1_in;
        input [31:0]oprand2_in;
        input [31:0]exp_out;

        begin
            checks = checks + 1;
            opcode  = opcode_in;
            oprand1 = oprand1_in;
            oprand2 = oprand2_in;
            #1;                                  // ★ 等组合逻辑稳定再比对（关键！）
            if(exp_out !== out_comb)begin        // ★ 用 !== ：!= 遇到 X 会得到 X，被 if 当成假 → 假通过
                errors = errors + 1;
                $display("  [FAIL] %0s  opcode=%b oprand1=%h oprand2=%h  期望=%h 实际=%h",
                         name, opcode_in, oprand1_in, oprand2_in, exp_out, out_comb);
            end
            else begin
                $display("  [ ok ] %0s  (%h , %h) -> %h", name, oprand1_in, oprand2_in, out_comb);
            end
        end
    endtask

    initial begin
        $display("=== TB_alu：ALU 组合通路测试（只看 out_comb）===");

        // ---------------- ADD ----------------
        exam_comb("add 0+1",        OP_ADD, 32'h0,         32'h1,         32'h1);
        exam_comb("add -2+1",       OP_ADD, 32'hffff_fffe, 32'h1,         32'hffff_ffff);
        exam_comb("add 溢出回绕",    OP_ADD, 32'hffff_ffff, 32'h1,         32'h0);
        exam_comb("add 有符号溢出",  OP_ADD, 32'h7fff_ffff, 32'h1,         32'h8000_0000);
        // ---------------- SUB ----------------
        exam_comb("sub 0-1",        OP_SUB, 32'h0,         32'h1,         32'hffff_ffff);
        exam_comb("sub 相等",        OP_SUB, 32'h5,         32'h5,         32'h0);
        exam_comb("sub -2-1",       OP_SUB, 32'hffff_fffe, 32'h1,         32'hffff_fffd);
        // ---------------- AND / OR / XOR ----------------
        exam_comb("and",            OP_AND, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'h00f0_00f0);
        exam_comb("or",             OP_OR,  32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'hfff0_fff0);
        exam_comb("xor",            OP_XOR, 32'hf0f0_f0f0, 32'h0ff0_0ff0, 32'hff00_ff00);
        // ---------------- 移位 ----------------
        exam_comb("sll 1<<4",       OP_SLL, 32'h1,         32'h4,         32'h10);
        exam_comb("sll 移位量>31",   OP_SLL, 32'h1,         32'h21,        32'h2);          // 只取低 5 位 → 相当于左移 1
        exam_comb("srl 逻辑右移",    OP_SRL, 32'hffff_ffff, 32'h4,         32'h0fff_ffff);
        exam_comb("sra 算术右移",    OP_SRA, 32'hffff_ffff, 32'h4,         32'hffff_ffff);  // 同输入，结果必须和 srl 不同
        // ---------------- SLT / SLTU：同一组输入，看有符号/无符号的区别 ----------------
        exam_comb("slt -1<1",       OP_SLT,  32'hffff_ffff, 32'h1,        32'h1);
        exam_comb("sltu 同输入",     OP_SLTU, 32'hffff_ffff, 32'h1,        32'h0);
        // ---------------- EQ ----------------
        exam_comb("eq 相等",         OP_EQ,  32'h1234,      32'h1234,     32'h1);
        exam_comb("eq 不等",         OP_EQ,  32'h1234,      32'h1235,     32'h0);
        // ---------------- 未定义 opcode（decoder 不会给出，只确认不瞎写）----------------
        exam_comb("未定义 opcode",   4'b1111, 32'h1234,      32'h5678,     32'h0);

        $display("\n=== 共检查 %0d 项，失配 %0d 项 ===", checks, errors);
        if (errors == 0) $display(">>> 全部通过 <<<\n");
        else             $display(">>> 有 %0d 项不符，见上面 [FAIL] <<<\n", errors);

        $finish;
    end
    

endmodule   
