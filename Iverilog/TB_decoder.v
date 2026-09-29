`timescale 1ns/1ps

module TB_decoder ();

    // ---------------- 时钟与激励 ----------------
    reg         clk         = 1'b0;
    reg  [31:0] instruction = 32'h0;
    reg         valid_in    = 1'b0;
    reg         flush       = 1'b0;
    reg         stall       = 1'b0;

    // ---------------- DUT 输出 ----------------
    wire [4:0]  rs1_addr;
    wire [4:0]  rs2_addr;
    wire [4:0]  rd_addr;

    wire        RegWrite;
    wire        MemRead;
    wire        MemWrite;
    wire [1:0]  MemSize;
    wire        MemUnsigned;
    wire [1:0]  wb_type;
    wire        ALUen;
    wire        ALUSrc1;
    wire        ALUSrc2;
    wire [3:0]  ALUOp;
    wire        Branch;
    wire [2:0]  Branch_type;
    wire        Jump;
    wire [31:0] immediate;
    wire        valid_out;

    // ---------------- 测试统计 ----------------
    integer    errors = 0;
    integer    checks = 0;
    reg [31:0] ins;                 // 当前正在测试的指令

    always #10 clk = ~clk;          // 20ns 周期


    
    decoder u_decoder(
        .instruction (instruction ),
        .clk         (clk         ),
        .valid_in    (valid_in    ),
        .flush       (flush       ),
        .stall       (stall       ),
        .rs1_addr    (rs1_addr    ),
        .rs2_addr    (rs2_addr    ),
        .rd_addr     (rd_addr     ),
        .RegWrite    (RegWrite    ),
        .MemRead     (MemRead     ),
        .MemWrite    (MemWrite    ),
        .MemSize     (MemSize     ),
        .MemUnsigned (MemUnsigned ),
        .wb_type     (wb_type     ),
        .ALUen       (ALUen       ),
        .ALUSrc1     (ALUSrc1     ),
        .ALUSrc2     (ALUSrc2     ),
        .ALUOp       (ALUOp       ),
        .Branch      (Branch      ),
        .Branch_type (Branch_type ),
        .Jump        (Jump        ),
        .immediate   (immediate   ),
        .valid_out   (valid_out   )
    );

    // =====================================================================
    //  RV32I decoder 自检测试台
    //  -----------------------------------------------------------------
    //  · 期望值按 RV32I 规范书写，而不是照抄 RTL 现有行为，
    //    因此出现 [FAIL] 表示 RTL 与规范不符，需要人工确认。
    //  · DUT 是时序逻辑：控制信号在 posedge 更新。所以 drive() 的做法是
    //    negedge 摆激励 → posedge 让 DUT 采样 → #1 等非阻塞赋值结算 → 再检查。
    //  · 传给 expect_* 任务的 name 用固定 256bit 的字符串传递，
    //    所以只能用 ASCII 且不超过 32 个字符（1 个中文占 3 字节会被截断）。
    // =====================================================================

    // ---- ALUOp 编码（必须与 ALU.v 中的 localparam 一致）----
    localparam ALU_ADD  = 4'd0;
    localparam ALU_SUB  = 4'd1;
    localparam ALU_AND  = 4'd2;
    localparam ALU_OR   = 4'd3;
    localparam ALU_XOR  = 4'd4;
    localparam ALU_SLL  = 4'd5;
    localparam ALU_SRL  = 4'd6;
    localparam ALU_SRA  = 4'd7;
    localparam ALU_SLT  = 4'd8;
    localparam ALU_SLTU = 4'd9;
    localparam ALU_EQ   = 4'd10;

    // ---- Branch_type 编码（= branch 指令的 funct3）----
    localparam BT_BEQ  = 3'h0;
    localparam BT_BNE  = 3'h1;
    localparam BT_BLT  = 3'h4;
    localparam BT_BGE  = 3'h5;
    localparam BT_BLTU = 3'h6;
    localparam BT_BGEU = 3'h7;

    // ---- RV32I opcode[6:0] ----
    localparam OPC_R      = 7'b0110011;
    localparam OPC_I_ALU  = 7'b0010011;
    localparam OPC_LOAD   = 7'b0000011;
    localparam OPC_JALR   = 7'b1100111;
    localparam OPC_STORE  = 7'b0100011;
    localparam OPC_BRANCH = 7'b1100011;
    localparam OPC_LUI    = 7'b0110111;
    localparam OPC_AUIPC  = 7'b0010111;
    localparam OPC_JAL    = 7'b1101111;

    // ---- wb_type 编码（独立定义，用于交叉检查 RTL 的同一编码）----
    localparam WB_ALU = 2'b00;
    localparam WB_MEM = 2'b01;
    localparam WB_IMM = 2'b10;
    localparam WB_PC4 = 2'b11;

    // ---- MemSize 编码（load/store 共用宽度）----
    localparam MS_BYTE = 2'b00;
    localparam MS_HALF = 2'b01;
    localparam MS_WORD = 2'b10;

    // ---- 各类指令「应有的」控制信号组合 ----
    //  e_dp = {RegWrite, MemRead, MemWrite, MemSize[1:0], MemUnsigned,
    //          wb_type[1:0], ALUen, ALUSrc1, ALUSrc2}
    //  ★ RTL 现在对**每条指令**都给出确定值（用不到的信号走统一默认值），
    //    所以这里不再有 don't care —— 每一位都可以无条件比较。
    //    · 地址类默认 x0   · 其余控制信号默认中性值（00 / 0 / OP_ADD）
    localparam DP_R      = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_ALU, 1'b1, 1'b0, 1'b1}; // R 型
    localparam DP_IALU   = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_ALU, 1'b1, 1'b0, 1'b0}; // I 型算术
    localparam DP_JALR   = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_PC4, 1'b1, 1'b0, 1'b0}; // JALR
    localparam DP_BRANCH = {1'b0, 1'b0, 1'b0, 2'b00,   1'b0, WB_ALU, 1'b1, 1'b0, 1'b1}; // branch
    localparam DP_LUI    = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_IMM, 1'b0, 1'b0, 1'b0}; // LUI：不用 ALU
    localparam DP_AUIPC  = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_ALU, 1'b1, 1'b1, 1'b0}; // AUIPC：A 口取 PC
    localparam DP_JAL    = {1'b1, 1'b0, 1'b0, 2'b00,   1'b0, WB_PC4, 1'b1, 1'b1, 1'b0}; // JAL：目标 PC+imm 走 ALU
    localparam DP_SYS    = {1'b0, 1'b0, 1'b0, 2'b00,   1'b0, WB_ALU, 1'b0, 1'b0, 1'b0}; // SYSTEM/非法
    // load / store 按 funct3 拆开：宽度和符号扩展必须能被区分。
    // lw 的 MemUnsigned 也无条件定为 0（字宽不需要扩展，取的就是 funct3[2]=0）
    localparam DP_LB     = {1'b1, 1'b1, 1'b0, MS_BYTE, 1'b0, WB_MEM, 1'b1, 1'b0, 1'b0};
    localparam DP_LH     = {1'b1, 1'b1, 1'b0, MS_HALF, 1'b0, WB_MEM, 1'b1, 1'b0, 1'b0};
    localparam DP_LW     = {1'b1, 1'b1, 1'b0, MS_WORD, 1'b0, WB_MEM, 1'b1, 1'b0, 1'b0};
    localparam DP_LBU    = {1'b1, 1'b1, 1'b0, MS_BYTE, 1'b1, WB_MEM, 1'b1, 1'b0, 1'b0};
    localparam DP_LHU    = {1'b1, 1'b1, 1'b0, MS_HALF, 1'b1, WB_MEM, 1'b1, 1'b0, 1'b0};
    localparam DP_SB     = {1'b0, 1'b0, 1'b1, MS_BYTE, 1'b0, WB_ALU, 1'b1, 1'b0, 1'b0};
    localparam DP_SH     = {1'b0, 1'b0, 1'b1, MS_HALF, 1'b0, WB_ALU, 1'b1, 1'b0, 1'b0};
    localparam DP_SW     = {1'b0, 1'b0, 1'b1, MS_WORD, 1'b0, WB_ALU, 1'b1, 1'b0, 1'b0};

    // ---------------------------------------------------------------------
    //  指令编码构造：按手册字段摆位，避免手写 32 位常量出错
    // ---------------------------------------------------------------------
    function [31:0] R_TYPE;
        input [6:0] f7; input [4:0] rs2; input [4:0] rs1; input [2:0] f3; input [4:0] rd;
        begin R_TYPE = {f7, rs2, rs1, f3, rd, OPC_R}; end
    endfunction

    function [31:0] I_TYPE;
        input [11:0] imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd; input [6:0] opc;
        begin I_TYPE = {imm, rs1, f3, rd, opc}; end
    endfunction

    function [31:0] S_TYPE;
        input [11:0] imm; input [4:0] rs2; input [4:0] rs1; input [2:0] f3;
        begin S_TYPE = {imm[11:5], rs2, rs1, f3, imm[4:0], OPC_STORE}; end
    endfunction

    function [31:0] B_TYPE;
        input [12:0] imm; input [4:0] rs2; input [4:0] rs1; input [2:0] f3;
        begin B_TYPE = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], OPC_BRANCH}; end
    endfunction

    function [31:0] U_TYPE;
        input [19:0] imm; input [4:0] rd; input [6:0] opc;
        begin U_TYPE = {imm, rd, opc}; end
    endfunction

    function [31:0] J_TYPE;
        input [20:0] imm; input [4:0] rd;
        begin J_TYPE = {imm[20], imm[10:1], imm[11], imm[19:12], rd, OPC_JAL}; end
    endfunction

    // ---------------------------------------------------------------------
    //  激励 / 检查任务
    // ---------------------------------------------------------------------
    task reset_dut;
        begin
            @(negedge clk);
            instruction = 32'h0;
            valid_in    = 1'b0;
            stall       = 1'b0;
            flush       = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            @(negedge clk);
            flush = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // 摆激励 → 一个时钟沿 → 等非阻塞赋值结算
    task drive;
        input [31:0] instr;
        input        v;
        input        f;
        input        s;
        begin
            @(negedge clk);
            instruction = instr;
            valid_in    = v;
            flush       = f;
            stall       = s;
            @(posedge clk);
            #1;
        end
    endtask

    // 地址三个端口现在**每条指令都有确定值**：真读/写寄存器的桶给真实编号，
    // 其余桶给默认值 x0（x0 永远不会被写，所以不可能造成假依赖）。
    // 因此三个都无条件检查——mask 参数保留只为兼容调用点，已不再使用。
    task expect_regs;
        input [255:0] name;
        input [4:0]   e_rs1;
        input [4:0]   e_rs2;
        input [4:0]   e_rd;
        input [2:0]   mask;
        begin
            checks = checks + 3;
            if (rs1_addr !== e_rs1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  rs1_addr = x%0d，期望 x%0d", name, rs1_addr, e_rs1);
            end
            if (rs2_addr !== e_rs2) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  rs2_addr = x%0d，期望 x%0d", name, rs2_addr, e_rs2);
            end
            if (rd_addr !== e_rd) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  rd_addr = x%0d，期望 x%0d", name, rd_addr, e_rd);
            end
        end
    endtask

    //  ------------------------------------------------------------------
    //  期望值参数
    //  ------------------------------------------------------------------
    //  name     : 指令文本（打印用，必须 ASCII 且 <= 32 字符）
    //  e_imm    : 期望 immediate（已按规范符号扩展）
    //  chk_imm  : 保留参数（兼容调用点）；immediate 现在恒有确定值，一律检查
    //  e_dp     : {RegWrite, MemRead, MemWrite, MemSize[1:0], MemUnsigned,
    //               wb_type[1:0], ALUen, ALUSrc1, ALUSrc2}
    //  e_bj     : {Branch, Jump}
    //  e_aluop  : 期望 ALUOp
    //  e_btype  : 期望 Branch_type
    //  e_valid  : 期望 valid_out
    //
    //  ★ RTL 现在对每条指令都给出确定的默认值（不再"保持旧值"），
    //    所以这里**没有任何条件门控**：每个信号每一拍都断言。
    //    检查强度比之前更高 —— 之前那些 don't care 位现在也全在查。
    //  ------------------------------------------------------------------
    task expect_ctrl;
        input [255:0] name;
        input [31:0]  e_imm;
        input         chk_imm;
        input [10:0]  e_dp;
        input [1:0]   e_bj;
        input [3:0]   e_aluop;
        input [2:0]   e_btype;
        input         e_valid;
        integer       e0;
        begin
            e0 = errors;
            checks = checks + 11;

            if ({RegWrite, MemRead, MemWrite} !== e_dp[10:8]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  {RegWrite,MemRead,MemWrite} = %b，期望 %b",
                         name, {RegWrite, MemRead, MemWrite}, e_dp[10:8]);
            end
            if (ALUen !== e_dp[2]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  ALUen = %b，期望 %b", name, ALUen, e_dp[2]);
            end
            if ({Branch, Jump} !== e_bj) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  {Branch,Jump} = %b，期望 %b", name, {Branch, Jump}, e_bj);
            end
            if (MemSize !== e_dp[7:6]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  MemSize = %b，期望 %b", name, MemSize, e_dp[7:6]);
            end
            if (MemUnsigned !== e_dp[5]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  MemUnsigned = %b，期望 %b", name, MemUnsigned, e_dp[5]);
            end
            if (wb_type !== e_dp[4:3]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  wb_type = %0d，期望 %0d", name, wb_type, e_dp[4:3]);
            end
            if ({ALUSrc1, ALUSrc2} !== e_dp[1:0]) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  {ALUSrc1,ALUSrc2} = %b，期望 %b",
                         name, {ALUSrc1, ALUSrc2}, e_dp[1:0]);
            end
            if (ALUOp !== e_aluop) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  ALUOp = %0d，期望 %0d", name, ALUOp, e_aluop);
            end
            if (Branch_type !== e_btype) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  Branch_type = %0d，期望 %0d", name, Branch_type, e_btype);
            end
            if (immediate !== e_imm) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  immediate = %h，期望 %h", name, immediate, e_imm);
            end
            if (valid_out !== e_valid) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  valid_out = %b，期望 %b", name, valid_out, e_valid);
            end

            if (errors == e0) $display("  [ ok ] %0s", name);
        end
    endtask

    task expect_valid;
        input [255:0] name;
        input         e;
        begin
            checks = checks + 1;
            if (valid_out !== e) begin
                errors = errors + 1;
                $display("  [FAIL] %0s  valid_out = %b，期望 %b", name, valid_out, e);
            end
            else $display("  [ ok ] %0s  valid_out = %b", name, valid_out);
        end
    endtask

    // =====================================================================
    //  测试序列
    // =====================================================================
    initial begin
        $dumpfile("TB_decoder.vcd");
        $dumpvars(0, TB_decoder);

        $display("\n======================================================");
        $display("  RV32I decoder 自检测试台");
        $display("======================================================");

        // -----------------------------------------------------------------
        // 0. 复位
        // -----------------------------------------------------------------
        reset_dut;
        $display("\n--- 0. 复位后（控制信号应全 0，valid_out = 0）---");
        expect_ctrl("reset", 32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b0);

        // -----------------------------------------------------------------
        // 1. R 型指令 (opcode 0110011)
        // -----------------------------------------------------------------
        $display("\n--- 1. R 型指令 ---");

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b000, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("add  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("add  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_ADD,  3'd0, 1'b1);

        ins = R_TYPE(7'h20, 5'd2, 5'd1, 3'b000, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sub  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("sub  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SUB,  3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b001, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sll  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("sll  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SLL,  3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b010, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("slt  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("slt  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SLT,  3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b011, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sltu x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("sltu x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SLTU, 3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b100, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("xor  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("xor  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_XOR,  3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b101, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("srl  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("srl  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SRL,  3'd0, 1'b1);

        ins = R_TYPE(7'h20, 5'd2, 5'd1, 3'b101, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sra  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("sra  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_SRA,  3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b110, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("or   x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("or   x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_OR,   3'd0, 1'b1);

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b111, 5'd3); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("and  x3,x1,x2",  5'd1, 5'd2, 5'd3, 3'b111);
        expect_ctrl("and  x3,x1,x2",  32'd0, 1'b0, DP_R, 2'b00, ALU_AND,  3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 2. I 型算术/逻辑 (opcode 0010011)
        //    立即数必须符号扩展：负立即数会暴露 RTL 的零扩展问题
        // -----------------------------------------------------------------
        $display("\n--- 2. I 型算术/逻辑 ---");

        ins = I_TYPE(12'h001, 5'd1, 3'b000, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("addi  x3,x1,1",   5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("addi  x3,x1,1",   32'h0000_0001, 1'b1, DP_IALU, 2'b00, ALU_ADD,  3'd0, 1'b1);

        ins = I_TYPE(12'hFFF, 5'd1, 3'b000, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("addi  x3,x1,-1",  5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("addi  x3,x1,-1",  32'hFFFF_FFFF, 1'b1, DP_IALU, 2'b00, ALU_ADD,  3'd0, 1'b1);

        ins = I_TYPE(12'h7FF, 5'd1, 3'b010, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("slti  x3,x1,2047", 5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("slti  x3,x1,2047", 32'h0000_07FF, 1'b1, DP_IALU, 2'b00, ALU_SLT,  3'd0, 1'b1);

        ins = I_TYPE(12'h7FF, 5'd1, 3'b011, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sltiu x3,x1,2047", 5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("sltiu x3,x1,2047", 32'h0000_07FF, 1'b1, DP_IALU, 2'b00, ALU_SLTU, 3'd0, 1'b1);

        ins = I_TYPE(12'h0F0, 5'd1, 3'b100, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("xori  x3,x1,240", 5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("xori  x3,x1,240", 32'h0000_00F0, 1'b1, DP_IALU, 2'b00, ALU_XOR,  3'd0, 1'b1);

        ins = I_TYPE(12'h0F0, 5'd1, 3'b110, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("ori   x3,x1,240", 5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("ori   x3,x1,240", 32'h0000_00F0, 1'b1, DP_IALU, 2'b00, ALU_OR,   3'd0, 1'b1);

        ins = I_TYPE(12'h0F0, 5'd1, 3'b111, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("andi  x3,x1,240", 5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("andi  x3,x1,240", 32'h0000_00F0, 1'b1, DP_IALU, 2'b00, ALU_AND,  3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b001, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("slli  x3,x1,4",  5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("slli  x3,x1,4",  32'h0000_0004, 1'b1, DP_IALU, 2'b00, ALU_SLL,  3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b101, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("srli  x3,x1,4",  5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("srli  x3,x1,4",  32'h0000_0004, 1'b1, DP_IALU, 2'b00, ALU_SRL,  3'd0, 1'b1);

        // srai 的 imm[11:5] 是 funct7 = 0100000
        ins = I_TYPE(12'h404, 5'd1, 3'b101, 5'd3, OPC_I_ALU); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("srai  x3,x1,4",  5'd1, 5'd0, 5'd3, 3'b101);
        expect_ctrl("srai  x3,x1,4",  32'h0000_0404, 1'b1, DP_IALU, 2'b00, ALU_SRA,  3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 3. load (opcode 0000011)
        //    ★ 5 条 load 的宽度和符号扩展各不相同，必须分开测：
        //      lb/lh/lw 有符号扩展，lbu/lhu 零扩展；宽度由 funct3[1:0] 给出。
        //      之前 5 条共用同一个 DP_LOAD 常量，等于断言它们"输出完全相同"，
        //      把一个缺失信号固化了。
        // -----------------------------------------------------------------
        $display("\n--- 3. Load (lb/lh/lw/lbu/lhu) ---");

        ins = I_TYPE(12'h004, 5'd1, 3'b000, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lb   x4,4(x1)",   5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lb   x4,4(x1)",   32'h0000_0004, 1'b1, DP_LB,  2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b001, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lh   x4,4(x1)",   5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lh   x4,4(x1)",   32'h0000_0004, 1'b1, DP_LH,  2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b010, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lw   x4,4(x1)",   5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lw   x4,4(x1)",   32'h0000_0004, 1'b1, DP_LW,  2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b100, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lbu  x4,4(x1)",   5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lbu  x4,4(x1)",   32'h0000_0004, 1'b1, DP_LBU, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'h004, 5'd1, 3'b101, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lhu  x4,4(x1)",   5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lhu  x4,4(x1)",   32'h0000_0004, 1'b1, DP_LHU, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'hFFC, 5'd1, 3'b010, 5'd4, OPC_LOAD); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lw   x4,-4(x1)",  5'd1, 5'd0, 5'd4, 3'b101);
        expect_ctrl("lw   x4,-4(x1)",  32'hFFFF_FFFC, 1'b1, DP_LW,  2'b00, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 4. JALR (opcode 1100111)
        // -----------------------------------------------------------------
        $display("\n--- 4. JALR ---");

        ins = I_TYPE(12'h008, 5'd2, 3'b000, 5'd1, OPC_JALR); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("jalr x1,x2,8",   5'd2, 5'd0, 5'd1, 3'b101);
        expect_ctrl("jalr x1,x2,8",   32'h0000_0008, 1'b1, DP_JALR, 2'b01, ALU_ADD, 3'd0, 1'b1);

        ins = I_TYPE(12'hFF8, 5'd2, 3'b000, 5'd1, OPC_JALR); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("jalr x1,x2,-8",  5'd2, 5'd0, 5'd1, 3'b101);
        expect_ctrl("jalr x1,x2,-8",  32'hFFFF_FFF8, 1'b1, DP_JALR, 2'b01, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 5. store (opcode 0100011)
        //    MemWrite 只应在 store 上拉高；其它类型都必须为 0
        // -----------------------------------------------------------------
        $display("\n--- 5. Store ---");

        // @note store 的数据来源就是 x[rs2]，它和 ALUSrc 完全无关！
        //       所以这里刻意让 rs2 取"与前面被保持下来的值不同"的寄存器
        //       （section 1 最后一条 R 型把 rs2_addr 停在 x2）。
        //       否则 rs2 恰好等于保持值，这个 bug 会被蒙混过去。
        ins = S_TYPE(12'h008, 5'd5, 5'd1, 3'b010); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sw   x5,8(x1)",  5'd1, 5'd5, 5'd0, 3'b110);
        expect_ctrl("sw   x5,8(x1)",  32'h0000_0008, 1'b1, DP_SW, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = S_TYPE(12'hFFC, 5'd6, 5'd1, 3'b010); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sw   x6,-4(x1)", 5'd1, 5'd6, 5'd0, 3'b110);
        expect_ctrl("sw   x6,-4(x1)", 32'hFFFF_FFFC, 1'b1, DP_SW, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = S_TYPE(12'h008, 5'd7, 5'd1, 3'b000); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sb   x7,8(x1)",  5'd1, 5'd7, 5'd0, 3'b110);
        expect_ctrl("sb   x7,8(x1)",  32'h0000_0008, 1'b1, DP_SB, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = S_TYPE(12'h008, 5'd8, 5'd1, 3'b001); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sh   x8,8(x1)",  5'd1, 5'd8, 5'd0, 3'b110);
        expect_ctrl("sh   x8,8(x1)",  32'h0000_0008, 1'b1, DP_SH, 2'b00, ALU_ADD, 3'd0, 1'b1);

        // S 型的立即数最低位 imm[0] = instruction[7]，它夹在 rs2/rs1 之间，
        // 拼接时最容易漏掉；所以专门用奇数偏移来探这一位。
        ins = S_TYPE(12'h007, 5'd5, 5'd1, 3'b010); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sw   x5,7(x1)",  5'd1, 5'd5, 5'd0, 3'b110);
        expect_ctrl("sw   x5,7(x1)",  32'h0000_0007, 1'b1, DP_SW, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = S_TYPE(12'hFFF, 5'd5, 5'd1, 3'b010); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("sw   x5,-1(x1)", 5'd1, 5'd5, 5'd0, 3'b110);
        expect_ctrl("sw   x5,-1(x1)", 32'hFFFF_FFFF, 1'b1, DP_SW, 2'b00, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 6. branch (opcode 1100011)
        // -----------------------------------------------------------------
        $display("\n--- 6. Branch ---");

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b000); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("beq  x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("beq  x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_EQ,  BT_BEQ,  1'b1);

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b001); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("bne  x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("bne  x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_EQ,  BT_BNE,  1'b1);

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b100); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("blt  x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("blt  x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_SLT,  BT_BLT,  1'b1);

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b101); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("bge  x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("bge  x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_SLT,  BT_BGE,  1'b1);

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b110); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("bltu x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("bltu x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_SLTU, BT_BLTU, 1'b1);

        ins = B_TYPE(13'h0010, 5'd2, 5'd1, 3'b111); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("bgeu x1,x2,+16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("bgeu x1,x2,+16", 32'h0000_0010, 1'b1, DP_BRANCH, 2'b10, ALU_SLTU, BT_BGEU, 1'b1);

        ins = B_TYPE(13'h1FF0, 5'd2, 5'd1, 3'b000); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("beq  x1,x2,-16", 5'd1, 5'd2, 5'd0, 3'b110);
        expect_ctrl("beq  x1,x2,-16", 32'hFFFF_FFF0, 1'b1, DP_BRANCH, 2'b10, ALU_EQ,  BT_BEQ,  1'b1);

        // -----------------------------------------------------------------
        // 7. U 型 (LUI / AUIPC)
        //    ★ 这两条必须分开测：立即数完全相同，但**运算不同**
        //        LUI   : rd = imm            （不用 ALU）
        //        AUIPC : rd = PC + imm        （必须开 ALU，且 A 口取 PC）
        //    唯一能区分它们的信号就是 ALUSrc1=1。之前把它们归成一个
        //    DP_LUI 常量，等于把"没区分"固化成了期望值，AUIPC 就这样漏掉了。
        //    这里也顺带覆盖"从保持值恢复"：LUI 时 ALU 信号是保持的，
        //    紧跟的 AUIPC 必须把它们更新成 ALUen=1 / ALUSrc1=1。
        // -----------------------------------------------------------------
        $display("\n--- 7. U 型指令 (LUI / AUIPC) ---");

        ins = U_TYPE(20'h12345, 5'd5, OPC_LUI); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lui   x5,0x12345", 5'd0, 5'd0, 5'd5, 3'b001);
        expect_ctrl("lui   x5,0x12345", 32'h1234_5000, 1'b1, DP_LUI, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = U_TYPE(20'h80000, 5'd5, OPC_AUIPC); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("auipc x5,0x80000", 5'd0, 5'd0, 5'd5, 3'b001);
        expect_ctrl("auipc x5,0x80000", 32'h8000_0000, 1'b1, DP_AUIPC, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = U_TYPE(20'h00001, 5'd6, OPC_AUIPC); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("auipc x6,0x00001", 5'd0, 5'd0, 5'd6, 3'b001);
        expect_ctrl("auipc x6,0x00001", 32'h0000_1000, 1'b1, DP_AUIPC, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = U_TYPE(20'hFFFFF, 5'd5, OPC_LUI); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("lui   x5,0xFFFFF", 5'd0, 5'd0, 5'd5, 3'b001);
        expect_ctrl("lui   x5,0xFFFFF", 32'hFFFF_F000, 1'b1, DP_LUI, 2'b00, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 8. JAL (opcode 1101111)
        // -----------------------------------------------------------------
        $display("\n--- 8. JAL ---");

        ins = J_TYPE(21'h000010, 5'd1); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("jal  x1,+16",  5'd0, 5'd0, 5'd1, 3'b001);
        expect_ctrl("jal  x1,+16",  32'h0000_0010, 1'b1, DP_JAL, 2'b01, ALU_ADD, 3'd0, 1'b1);

        ins = J_TYPE(21'h1FFFF0, 5'd1); drive(ins, 1'b1, 1'b0, 1'b0);
        expect_regs("jal  x1,-16",  5'd0, 5'd0, 5'd1, 3'b001);
        expect_ctrl("jal  x1,-16",  32'hFFFF_FFF0, 1'b1, DP_JAL, 2'b01, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 9. SYSTEM / FENCE / 非法指令
        // -----------------------------------------------------------------
        $display("\n--- 9. SYSTEM / FENCE / 非法指令 ---");

        // ecall / ebreak / fence 既不读寄存器也不写寄存器（RegWrite=0），
        // 三个地址端口在规范上都是 don't-care，故 mask=0 全部不检查。
        ins = 32'h0000_0073; drive(ins, 1'b1, 1'b0, 1'b0);        // ecall
        expect_regs("ecall",        5'd0, 5'd0, 5'd0, 3'b000);
        expect_ctrl("ecall",        32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = 32'h0010_0073; drive(ins, 1'b1, 1'b0, 1'b0);        // ebreak
        expect_regs("ebreak",       5'd0, 5'd0, 5'd0, 3'b000);
        expect_ctrl("ebreak",       32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = 32'h0000_000F; drive(ins, 1'b1, 1'b0, 1'b0);        // fence
        expect_regs("fence",        5'd0, 5'd0, 5'd0, 3'b000);
        expect_ctrl("fence",        32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = 32'h0000_0000; drive(ins, 1'b1, 1'b0, 1'b0);        // 非法 opcode 0
        expect_ctrl("illegal op=0", 32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = 32'hFFFF_FFFF; drive(ins, 1'b1, 1'b0, 1'b0);        // 非法 opcode 127
        expect_ctrl("illegal op=127", 32'h0000_0000, 1'b1, DP_SYS, 2'b00, ALU_ADD, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 10. valid_in -> valid_out 流水传递
        // -----------------------------------------------------------------
        $display("\n--- 10. valid_out 流水传递 ---");

        ins = I_TYPE(12'h001, 5'd1, 3'b000, 5'd3, OPC_I_ALU);
        drive(ins, 1'b1, 1'b0, 1'b0);
        expect_valid("valid_in=1 -> valid_out=1", 1'b1);

        drive(ins, 1'b0, 1'b0, 1'b0);
        expect_valid("valid_in=0 -> valid_out=0", 1'b0);

        drive(ins, 1'b1, 1'b0, 1'b0);
        expect_valid("valid_in=1 -> valid_out=1", 1'b1);

        // -----------------------------------------------------------------
        // 11. stall：保持控制信号与 valid_out
        // -----------------------------------------------------------------
        $display("\n--- 11. stall 保持 ---");

        ins = I_TYPE(12'h001, 5'd1, 3'b000, 5'd3, OPC_I_ALU);   // addi
        drive(ins, 1'b1, 1'b0, 1'b0);
        expect_ctrl("addi baseline", 32'h0000_0001, 1'b1, DP_IALU, 2'b00, ALU_ADD, 3'd0, 1'b1);

        ins = R_TYPE(7'h20, 5'd2, 5'd1, 3'b000, 5'd3);          // sub 但 stall=1
        drive(ins, 1'b1, 1'b0, 1'b1);
        expect_ctrl("stall=1: hold addi ctrl", 32'h0000_0001, 1'b1, DP_IALU, 2'b00, ALU_ADD, 3'd0, 1'b1);

        // sub 是 R 型，不驱动 immediate → 现在是默认值 0（以前是"保持"addi 的 1）
        drive(ins, 1'b1, 1'b0, 1'b0);                           // 释放 stall
        expect_ctrl("stall released: decode sub", 32'd0, 1'b1, DP_R, 2'b00, ALU_SUB, 3'd0, 1'b1);

        // -----------------------------------------------------------------
        // 12. flush：清 valid_out
        // -----------------------------------------------------------------
        $display("\n--- 12. flush ---");

        ins = R_TYPE(7'h00, 5'd2, 5'd1, 3'b000, 5'd3);          // add
        drive(ins, 1'b1, 1'b1, 1'b0);
        expect_valid("flush=1 -> valid_out=0", 1'b0);
        $display("  [info] flush 期间控制信号未被清除：RegWrite=%b, ALUOp=%0d（RTL 只清 valid_out）",
                 RegWrite, ALUOp);

        drive(ins, 1'b1, 1'b0, 1'b0);
        expect_valid("flush released -> valid_out=1", 1'b1);

        drive(ins, 1'b1, 1'b1, 1'b1);                           // flush 与 stall 同时
        expect_valid("flush=1 & stall=1 -> flush wins", 1'b0);
        $display("  [info] flush&stall 同时时控制信号被 stall 保持：ALUOp=%0d", ALUOp);

        // -----------------------------------------------------------------
        // 汇总
        // -----------------------------------------------------------------
        $display("\n======================================================");
        $display("  共检查 %0d 项，失配 %0d 项", checks, errors);
        if (errors == 0)
            $display("  >>> 全部通过 <<<");
        else
            $display("  >>> 有 %0d 项与 RV32I 规范期望不符，见上面 [FAIL] <<<", errors);
        $display("======================================================\n");

        $finish;
    end
    
endmodule
