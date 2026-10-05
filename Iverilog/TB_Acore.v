module TB_Acore();
    reg clk;
    reg rst_n;

    always #10 clk = ~clk;

    Acore u_Acore(
        .clk   (clk   ),
        .rst_n (rst_n )
    );
    
    
    initial begin
        clk = 0;
        repeat(150)@(posedge clk);
        $finish;
    end
    initial begin
        $dumpfile("TB_Acore.vcd");   // 波形文件名
        $dumpvars(0, TB_Acore);      // 0 表示转储所有层次的所有变量
    end

    // x0 恒 0：GPR_matrix 里没有它的实例（只 generate 出了 g_reg[1] .. g_reg[31]）
    wire [31:0] gpr [0:31];
    assign gpr[0] = 32'b0;

    genvar i;
    generate
        // ★ 从 1 开始：g_reg[0] 不存在，会报 "Unable to bind"
        for (i = 1; i < 32; i = i + 1) begin : g_peek
            assign gpr[i] = u_Acore.u_GPR_matrix.g_reg[i].u_Reg.dout;
        end
    endgenerate
    task init;
    begin
        $display("\n=========test rst=========");
        if(gpr[1] === 0)begin
            $display("Reset OK!\n");          
        end
        else begin
            $display(" Reset fail!\n");
            $display("gpr[1] = %d\n",gpr[1]); 
        end
            
    end
        
    endtask
    task exam_result;
        $display("\n=========test result=========");
        if(gpr[31] === 1)
            $display("result OK!\n"); 
        else begin
            $display(" result fail!\n");
            $display("gpr[1]=%0d,gpr[2]=%0d,gpr[3]=%0d\n",gpr[1],gpr[2],gpr[3]); 
            $display("pc=%0d",u_Acore.pc_IF );
        end
    endtask



    // 退休轨迹
    always @(posedge clk) begin
        if((u_Acore.wr_en_WB == 1) & (u_Acore.wr_addr_WB != 0))begin
            $display("Wr_GPR_addr = %0d  , Wr_GPR_data = %0d\n",u_Acore.wr_addr_WB,u_Acore.wr_data_WB);
        end
    end


    initial begin
        rst_n = 0;
        repeat(3)@(posedge clk);
        @(negedge clk);
        rst_n = 1;
        init;
        @(posedge clk);
        repeat(140)@(posedge clk);
        exam_result;
    end
endmodule
