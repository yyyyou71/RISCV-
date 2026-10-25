`timescale 1ns/1ps
module tb_modules;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, we = 0;
    reg [31:0] a = 0, b = 0, wdata = 0, insn = 0;
    reg [3:0] op = 0;
    wire [31:0] result, r1, r2, imm;
    reg [4:0] rs1 = 0, rs2 = 0, rd = 0;
    wire [4:0] d_rs1, d_rs2, d_rd;
    wire use1,use2,d_we,pc_a,imm_b,load,store,branch,jal,jalr,illegal,ecall,ebreak;
    wire [2:0] f3;
    wire [3:0] alu;
    rv32_alu u_alu (.a(a),.b(b),.op(op),.result(result));
    rv32_regfile u_rf (.clk(clk),.rst(rst),.rs1(rs1),.rs2(rs2),.rdata1(r1),.rdata2(r2),.we(we),.rd(rd),.wdata(wdata));
    rv32_decode u_dec (.insn(insn),.rs1(d_rs1),.rs2(d_rs2),.rd(d_rd),.use_rs1(use1),.use_rs2(use2),.rd_write(d_we),
      .imm(imm),.alu_op(alu),.a_is_pc(pc_a),.b_is_imm(imm_b),.is_load(load),.is_store(store),.is_branch(branch),
      .is_jal(jal),.is_jalr(jalr),.funct3(f3),.illegal(illegal),.ecall(ecall),.ebreak(ebreak));
    integer fd,n,count,q;
    reg [31:0] op_word,expected;
    initial begin
        fd = $fopen("alu_vectors.txt","r");
        if (!fd) $fatal(1,"No ALU vectors");
        count = 0;
        while (!$feof(fd)) begin
            n = $fscanf(fd,"%h %h %h %h\n",a,b,op_word,expected);
            if (n == 4) begin
                op = op_word[3:0]; #1;
                if (result !== expected) $fatal(1,"ALU op=%0d a=%08x b=%08x got=%08x expected=%08x",op,a,b,result,expected);
                count = count + 1;
            end
        end
        $fclose(fd);
        repeat(2) @(posedge clk);
        @(negedge clk); rst = 0;
        for (q = 0; q < 32; q = q + 1) begin
            @(negedge clk); we = 1; rd = q; rs1 = q; rs2 = q;
            wdata = 32'h5a120000 + q;
            #1;
            if (r1 !== (q == 0 ? 0 : wdata) || r2 !== (q == 0 ? 0 : wdata))
                $fatal(1,"Register write-through/x0 failed %0d",q);
            @(posedge clk); #1;
        end
        @(negedge clk); we = 0;
        for (q = 0; q < 32; q = q + 1) begin
            rs1 = q; rs2 = 31-q; #1;
            if (r1 !== (q == 0 ? 0 : 32'h5a120000+q)) $fatal(1,"Read port 1 failed");
            if (r2 !== (q == 31 ? 0 : 32'h5a120000+31-q)) $fatal(1,"Read port 2 failed");
        end
        @(negedge clk); rst = 1; we = 1; rd = 4; wdata = 123;
        @(posedge clk); #1;
        @(negedge clk); rst = 0; we = 0;
        for (q = 0; q < 32; q = q + 1) begin
            rs1 = q; #1; if (r1 !== 0) $fatal(1,"Reset priority failed");
        end
        insn = 32'hfff10093; #1; // addi x1,x2,-1
        if (illegal || !use1 || use2 || !d_we || !imm_b || imm !== 32'hffffffff || d_rd != 1 || d_rs1 != 2)
            $fatal(1,"I immediate/control decode failed");
        insn = 32'hfe112e23; #1; // sw x1,-4(x2)
        if (illegal || !store || !use1 || !use2 || d_we || imm !== 32'hfffffffc)
            $fatal(1,"S immediate/control decode failed");
        insn = 32'hfe000ee3; #1; // beq x0,x0,-4
        if (illegal || !branch || imm !== 32'hfffffffc) $fatal(1,"B immediate decode failed");
        insn = 32'hffdff0ef; #1; // jal x1,-4
        if (illegal || !jal || imm !== 32'hfffffffc) $fatal(1,"J immediate decode failed");
        insn = 32'habcde097; #1;
        if (illegal || !pc_a || imm !== 32'habcde000) $fatal(1,"U immediate decode failed");
        insn = 32'h00000073; #1;
        if (!ecall || illegal || ebreak) $fatal(1,"ECALL decode failed");
        insn = 32'h00100073; #1;
        if (!ebreak || illegal || ecall) $fatal(1,"EBREAK decode failed");
        insn = 32'h0ff0000f; #1;
        if (illegal || load || store || d_we) $fatal(1,"FENCE decode failed");
        insn = 32'h0000100f; #1;
        if (!illegal) $fatal(1,"FENCE.I must be unsupported");
        insn = 32'h02011093; #1;
        if (!illegal) $fatal(1,"Illegal shift must trap");
        $display("MODULES_PASS alu_vectors=%0d regfile=all_registers decoder=10_cases",count);
        $finish;
    end
endmodule
