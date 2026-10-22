`timescale 1ns/1ps

module TB_Acore #(
    parameter [63:0] MAX_CYCLES = 500000,
    parameter [31:0] EXPECT_EXIT = 1,
    parameter integer MUL_PIPE_STAGES = 3
)();
    reg clk;
    reg rst_n;
    


    reg [31:0]dev_rdata;

    wire bus_err;
    wire [31:0]dev_addr_wr;
    wire [31:0]dev_addr_rd;
    wire [31:0]dev_wdata;

    wire dev_we;
    wire dev_re;

    wire [1:0]dev_size;

    // ===== 内存映射外设的地址 =====
    // 必须和 Acore.v 里 sel_dev 的窗口(0x0003_xxxx)、start.s 的 TOHOST 一致
    localparam DEV_BASE = 32'h0003_0000;
    localparam TOHOST   = DEV_BASE + 32'h00;     // 写任意值 → 结束仿真，写入值 = 退出码
    localparam PRINT    = DEV_BASE + 32'h04;     // 写任意值 → 打印到控制台，程序继续
    localparam PUTCHAR = DEV_BASE + 32'h08;      // 终端文字打印
    localparam CYCLE_COUNT = DEV_BASE + 32'h0C;  // 用于处理器读入时间


    // 计时器，用于记录cpu运行多少个周期
    reg [31:0] cycle_counter;
    always @(posedge clk) begin
        if (!rst_n)
            cycle_counter <= 32'd0;
        else
            cycle_counter <= cycle_counter + 32'd1;
    end

    // 看门狗：程序死循环时也要能收场（没它仿真会永远跑下去）
    // MAX_CYCLES 可通过 iverilog -P 覆盖，CoreMark 需要更长的运行时间。

    always #10 clk = ~clk;

    Acore #(.MUL_PIPE_STAGES(MUL_PIPE_STAGES)) u_Acore(
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .dev_we      (dev_we      ),
        .dev_re      (dev_re      ),
        .bus_err     (bus_err     ),
        .dev_addr_wr (dev_addr_wr ),
        .dev_addr_rd (dev_addr_rd ),
        .dev_wdata   (dev_wdata   ),
        .dev_size    (dev_size    ),
        .dev_rdata   (dev_rdata   )
    );

    
    // 波形转储和时序控制都挪到文件末尾那个【唯一的】 initial 里了

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

//=====================设备模型==========================
    // dev_rdata 必须【寄存一拍】输出，和 memory.v 的读口时序一致：
    //   第 n 拍 dev_re / dev_addr_rd 有效 → 第 n+1 拍 dev_rdata 有效
    // 这样它才和 rd_data_MEM / sel_dev_MEM / wb_type_MEM 对齐。
    // 如果这里给组合值，等轮到 WB 拍地址早就变了 → 读回垃圾。
    always @(posedge clk) begin
        if      (!rst_n) dev_rdata <= 32'h0;
        else if (dev_re)begin
            if(dev_addr_rd == CYCLE_COUNT)begin
                dev_rdata <= cycle_counter;
            end
            else dev_rdata <= 32'd0;
        end
    end

    // 统计量
    reg [63:0] cycles = 0;
    integer berr_cnt  = 0;
    integer print_cnt = 0;
    reg        done      = 0;
    reg [31:0] exit_code = 32'hDEADBEEF;

    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (bus_err) berr_cnt = berr_cnt + 1;
    end

//=====================设备写处理========================
    // tohost : 收工，写入值当退出码
    // print  : 打印一行，程序继续
    // 这里用【阻塞赋值】，这样同一个时间步里 while(!done) 就能看见它
    always @(posedge clk) begin
        if (rst_n && dev_we) begin
            if (dev_addr_wr == TOHOST) begin
                if (!done) begin
                    done      = 1'b1;
                    exit_code = dev_wdata;
                end
            end
            else if (dev_addr_wr == PRINT) begin
                print_cnt = print_cnt + 1;
                $display("  [print] %0d  (0x%08h)", dev_wdata, dev_wdata);
            end

            else if (dev_addr_wr == PUTCHAR) begin
                $write("%c", dev_wdata[7:0]);
            end
            
            else
                $display("  [设备] 未识别的写: addr=%h data=%h", dev_addr_wr, dev_wdata);
        end
    end

//=========================task============================
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

    // 结果判定完全由 tohost 送来，不再看任何 GPR
    task exam_result;
        begin
            $display("\n=========test result=========");
            if (!done) begin
                $display(" TIMEOUT  %0d 拍内没收到 tohost", cycles);
                $display("   pc=%h  gpr[1]=%0d gpr[2]=%0d gpr[10]=%0d",
                         u_Acore.pc, gpr[1], gpr[2], gpr[10]);
            end
            else if (exit_code === EXPECT_EXIT)
                $display(" PASS   exit_code=%0d   (%0d 拍)", exit_code, cycles);
            else
                $display(" FAIL   exit_code=%0d   (%0d 拍)", exit_code, cycles);

            if (print_cnt != 0) $display(" print 被调用 %0d 次", print_cnt);
            if (berr_cnt  != 0) $display(" bus_err 拉高 %0d 次（访问了未映射地址）", berr_cnt);
        end
    endtask

//=====================================================


//=====================仿真控制==========================
    // 结束的判定不在这里，而是在文件末尾那个【唯一的】 initial 里：
    //     while (!done && cycles < MAX_CYCLES) @(posedge clk);
    // done 由上面的"设备写处理"块置起。
    //
    // ★ 为什么必须只用一个 initial 管时序：
    //   两个 initial 各数各的拍会互相竞争 —— 之前 $finish 比 exam_result 早 30ns，
    //   结果检查一次都没跑到过，表现出来就是"既没成功也没失败"。

    // 退休轨迹：长程序会刷屏，需要时把下面这行的注释去掉
    // `define RETIRE_TRACE
`ifdef RETIRE_TRACE
    always @(posedge clk) begin
        if((u_Acore.wr_en_WB == 1) & (u_Acore.wr_addr_WB != 0))begin
            $display("Write GPR:  x%0d <- %0d", u_Acore.wr_addr_WB, u_Acore.wr_data_WB);
        end

        if(u_Acore.wr_en_MEM == 1)begin
            $display("Write Mem:  [%h] <- %h", u_Acore.wr_addr_MEM, u_Acore.wr_data_MEM);
        end
    end
`endif


//=====================唯一的时序 initial==========================
    initial begin
`ifndef NO_WAVES
        $dumpfile("TB_Acore.vcd");   // 波形文件名
        $dumpvars(0, TB_Acore);      // 0 表示转储所有层次的所有变量
`endif

        clk = 0;
        rst_n = 0;                
        repeat(3)@(posedge clk);
        @(negedge clk);              
        rst_n = 1;
        init;

        // 等 tohost，或者超时
        // 在下降沿检查，避开上升沿统计/设备处理的调度竞争。
        while (!done && cycles < MAX_CYCLES) @(negedge clk);

        exam_result;
        if (!done || exit_code !== EXPECT_EXIT || berr_cnt != 0)
            $fatal(1, "Simulation failed: timeout, exit status or bus error");
        $finish;
    end
endmodule
