module Acore #(
    // 必须与真实乘法 IP 的 Pipeline Stages 配置一致，默认 3 级。
    parameter integer MUL_PIPE_STAGES = 3,
    // 除法总开关：1=完整 RV32IM；0=裁掉除法硬件，保留 Zmmul 乘法。
    parameter integer ENABLE_DIV = 0,
    parameter integer ENABLE_DUAL = 0
)(
    input clk,
    input rst_n,
    // 同 clk 域的电平请求；中断源负责保持和撤销。跨时钟域需在源端同步。
    input timer_irq,

    // 设备总线（内存映射外设）
    output     dev_we,       // 写选通
    output     dev_re,       // 读选通
    output      bus_err,       // 访问了未映射地址

    output  [31:0] dev_addr_wr,     // 32位地址，写
    output  [31:0] dev_addr_rd,     // 32位地址，读
    output  [31:0] dev_wdata,
    output  [1:0]  dev_size,     // 00/01/10 = 字节/半字/字
    input  [31:0] dev_rdata
);
    // 统一一下：分支指令(B-type)计算分支条件时使用alu，计算跳转地址则使用独立加法器
    /* 
        跳转指令区分(JALR/JAL):
        JALR--- Jump <= 1; ALUSrc1 <= 0; ALUSrc2 <= 0; ALUen <= 1;
        JAL --- Jump <= 1; ALUSrc1 <= 1; ALUSrc2 <= 0; ALUen <= 1;
        在跳转指令中，需要被加载的PC都由ALU计算完成，不同的是两个计算加载的PC不相同，
        然后PC+4需要随流水线传递下来在WB阶段写入

        valid_out_EX+pc_EX
        这 7 个是死信号（redirect 提前到 EX 拍之后的副产品）
        ，删掉省触发器，留着当波形探针就用 lint_off 包一下
    */

    //===================================variable=====================================
    //------------PC-----------------
    wire [31:0]pc;
    wire load_pc_en;
    wire [31:0]load_pc;
    wire stall_pc;
    wire valid_out_pc;
    //---------state1-IF--------------
    wire [31:0]pc_IF;
    wire [31:0]pc_4_IF;
    wire [31:0]instruction;
    wire stall_IF;
    wire flush_IF;
    wire valid_in_IF;
    wire valid_out_IF;

    //----------stage2-ID--------------
    wire valid_in_ID;
    wire flush_ID;
    wire stall_ID;
    wire [4:0]rs1_addr_ID;
    wire [4:0]rs2_addr_ID;
    wire [4:0]rd_addr_ID;
    wire RegWrite_ID;
    wire MemRead_ID;
    wire MemWrite_ID;
    wire [1:0]MemSize_ID;
    wire MemUnsigned_ID;
    wire [1:0]wb_type_ID;
    wire ALUen_ID;
    wire ALUSrc1_ID;
    wire ALUSrc2_ID;
    wire [3:0]ALUOp_ID;
    wire [1:0]DivOp_ID;
    wire CSR_en_ID;
    wire [2:0] CSR_op_ID;
    wire [11:0] CSR_addr_ID;
    wire Mret_ID;
    wire Branch_ID;
    wire [2:0]Branch_type_ID;
    wire Jump_ID;
    wire [31:0]immediate_ID;
    wire valid_out_ID;

    reg [31:0]pc_ID;
    reg [31:0]pc_4_ID;
    wire stall;
    reg [31:0]pc_EX;
    wire second_valid_IF, head_prediction, pair_IF;
    wire [31:0] instruction_b, head_prediction_pc;
    wire b_valid_ID;
    wire [4:0] b_rs1_ID, b_rs2_ID, b_rd_ID;
    wire [31:0] b_immediate_ID, b_gpr1, b_gpr2, b_forward1, b_forward2;
    wire b_src1_ID, b_src2_ID, b_hit1, b_hit2;
    wire [3:0] b_op_ID;
    wire [1:0] b_wb_ID;
    wire [31:0] b_alu_comb;
    reg b_valid_EX, b_valid_MEM;
    reg [4:0] b_rd_EX, b_rd_MEM;
    reg [31:0] b_result_EX, b_result_MEM;
    reg retire_a_EX, retire_a_MEM;
    reg [31:0] instruction_ID, instruction_EX, instruction_MEM, b_instruction_ID;
    reg [31:0] b_instruction_EX, b_instruction_MEM, b_pc_EX, b_pc_MEM, retire_pc_MEM;
    reg [63:0] retired_count, secondary_count;

    generate if (ENABLE_DUAL != 0) begin : g_secondary
        acore_pair u_pair (
            .first(instruction), .second(instruction_b),
            .available(valid_out_IF && second_valid_IF && !head_prediction), .pair(pair_IF)
        );
        decoder #(.ENABLE_DIV(0)) u_decoder_b (
            .clk(clk), .rst_n(rst_n), .instruction(instruction_b),
            .valid_in(stall_ID ? b_valid_ID : pair_IF), .flush(flush_ID), .stall(stall_ID),
            .rs1_addr(b_rs1_ID), .rs2_addr(b_rs2_ID), .rd_addr(b_rd_ID),
            .RegWrite(), .MemRead(), .MemWrite(), .MemSize(), .MemUnsigned(),
            .wb_type(b_wb_ID), .ALUen(), .ALUSrc1(b_src1_ID), .ALUSrc2(b_src2_ID),
            .ALUOp(b_op_ID), .DivOp(), .CSR_en(), .CSR_op(), .CSR_addr(), .Mret(),
            .Branch(), .Branch_type(), .Jump(), .immediate(b_immediate_ID), .valid_out(b_valid_ID)
        );
        ALU u_alu_b (
            .clk(clk), .opcode(b_op_ID),
            .oprand1(b_src1_ID ? pc_ID + 32'd4 : (b_hit1 ? b_forward1 : b_gpr1)),
            .oprand2(b_src2_ID ? (b_hit2 ? b_forward2 : b_gpr2) : b_immediate_ID),
            .en(b_valid_ID), .flush(1'b0), .valid_in(b_valid_ID), .stall(stall),
            .out(), .out_comb(b_alu_comb), .valid_out()
        );
    end else begin : g_no_secondary
        assign pair_IF = 1'b0;
        assign b_valid_ID = 1'b0;
        assign b_rs1_ID = 5'b0;
        assign b_rs2_ID = 5'b0;
        assign b_rd_ID = 5'b0;
        assign b_immediate_ID = 32'b0;
        assign b_src1_ID = 1'b0;
        assign b_src2_ID = 1'b0;
        assign b_op_ID = 4'b0;
        assign b_wb_ID = 2'b0;
        assign b_alu_comb = 32'b0;
        assign b_hit1 = 1'b0;
        assign b_hit2 = 1'b0;
        assign b_forward1 = 32'b0;
        assign b_forward2 = 32'b0;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            b_valid_EX <= 0;
            b_valid_MEM <= 0;
            b_rd_EX <= 0;
            b_rd_MEM <= 0;
            b_result_EX <= 0;
            b_result_MEM <= 0;
            retire_a_EX <= 0;
            retire_a_MEM <= 0;
            retired_count <= 0;
            secondary_count <= 0;
            instruction_ID <= 0;
            b_instruction_ID <= 0;
            instruction_EX <= 0;
            instruction_MEM <= 0;
            b_instruction_EX <= 0;
            b_instruction_MEM <= 0;
            b_pc_EX <= 0;
            b_pc_MEM <= 0;
            retire_pc_MEM <= 0;
        end else begin
            b_valid_EX <= b_valid_ID && !stall;
            b_rd_EX <= (b_valid_ID && !stall) ? b_rd_ID : 5'd0;
            if (b_valid_ID && !stall)
                b_result_EX <= (b_wb_ID == 2'b10) ? b_immediate_ID : b_alu_comb;
            b_valid_MEM <= b_valid_EX;
            b_rd_MEM <= b_rd_EX;
            b_result_MEM <= b_result_EX;
            retire_a_EX <= valid_out_ID && !stall;
            retire_a_MEM <= retire_a_EX;
            if (!stall) begin
                instruction_ID <= instruction;
                b_instruction_ID <= instruction_b;
            end
            instruction_EX <= instruction_ID;
            instruction_MEM <= instruction_EX;
            b_instruction_EX <= b_instruction_ID;
            b_instruction_MEM <= b_instruction_EX;
            b_pc_EX <= pc_ID + 32'd4;
            b_pc_MEM <= b_pc_EX;
            retire_pc_MEM <= pc_EX;
            retired_count <= retired_count + {63'b0, retire_a_MEM} + {63'b0, b_valid_MEM};
            secondary_count <= secondary_count + {63'b0, b_valid_MEM};
        end
    end

    //------------stage3-EX-----------------
    wire [3:0]opcode_EX;
    wire [31:0]oprand1_EX;
    wire [31:0]oprand2_EX;
    wire en_EX;
    wire flush_EX;
    wire valid_in_EX;
    wire stall_EX;
    wire [31:0]out_EX;
    wire [31:0]alu_out_EX;
    wire valid_out_EX;
    wire [31:0]out_comb_EX;

    reg [4:0]rd_addr_EX_reg;
    reg RegWrite_EX;
    reg MemRead_EX;
    reg MemWrite_EX;
    reg [1:0]MemSize_EX;
    reg MemUnsigned_EX;
    reg [1:0]wb_type_EX;
    reg [31:0]imm_EX;
    reg [31:0]pc_4_EX;
    reg [31:0]rd_data2_EX;  // s-type指令提前采样rs2，给MEM准备


    //----------------IO port----------------------
    wire [31:0]addr_EX;    // 外设和内存公用地址
    wire sel_ram;                   // 内存有效
    wire sel_dev;                   // 外设有效
    

    //----------stage4-MEM------------------
    wire [1:0]MemSize_MEM;
    wire MemUnsigned_MEM;
    wire wr_en_MEM;
    wire [15:0]wr_addr_MEM;
    wire [31:0]wr_data_MEM;
    wire rd_en_MEM;
    wire [15:0]rd_addr_MEM;
    wire [31:0]rd_data_MEM;
    wire [31:0]rd_data_mem_dev_MEM;

    reg [4:0]rd_addr_MEM_reg;
    reg RegWrite_MEM;
    reg [31:0]ALU_OUT_MEM;
    reg [1:0]wb_type_MEM;
    reg [31:0]imm_MEM;
    reg [31:0]pc_4_MEM;

    // 和前面的valid关系不大，主要是为了解决stall引起的空泡问题
    reg valid_out_MEM;
    reg sel_dev_MEM;

    //-------------stage5-WB-----------------
    wire wr_en_WB;
    wire [4:0]wr_addr_WB;
    wire [31:0]wr_data_WB;
    wire [4:0]rd_addr1_GPR;
    wire [4:0]rd_addr2_GPR;
    wire [31:0]rd_data1_GPR;
    wire [31:0]rd_data2_GPR;

    // 和前面的valid关系不大，主要是为了解决stall引起的空泡问题
    reg valid_out_WB;

    // ------------冒险检测/前递--------------------
    wire hazard_rs1;
    wire hazard_rs2;
    wire load_stall;
    wire mul_instruction = valid_out_ID && ALUen_ID && (ALUOp_ID[3:2] == 2'b11);
    wire mul_busy;
    wire mul_ready;
    wire [31:0]mul_result;
    reg mul_select_EX;
    reg [31:0]mul_result_EX;
    wire div_instruction = (ENABLE_DIV != 0) && valid_out_ID && ALUen_ID && (ALUOp_ID == 4'b1011);
    wire div_busy;
    wire div_ready;
    wire [31:0]div_result;
    reg div_select_EX;
    reg [31:0]div_result_EX;
    reg csr_select_EX;
    reg [31:0] csr_result_EX;
    wire [31:0]rs1_data_hazard;
    wire [31:0]rs2_data_hazard;

    //-------------branch_predictor---------------
    wire J_predict;
    wire [31:0]pc_predict;
    wire [31:0]upd_pc;
    wire [1:0]upd_type;
    wire upd_en;            // 是否为跳转/分支指令
    wire upd_taken;         // 是否真的执行跳转
    wire [31:0]upd_target_pc;

    // 是否真正表示跳转
    wire J_taken;
    wire [31:0]J_pc;

    // 判断预测是否正确
    wire predict_correct;
    

    reg if_predict_PC;
    reg [31:0]pc_predict_PC;
    reg if_predict_IF;
    reg [31:0]pc_predict_IF;

    // CSR/中断接口：_ID 信号实际属于 ID/EX 中正在 EX 执行的指令。
    wire irq_request;
    wire irq_accept;
    wire mret_commit;
    wire [31:0] irq_entry_pc;
    wire [31:0] mret_target_pc;
    wire [31:0] irq_resume_pc;
    wire [31:0] csr_rdata;
    wire [31:0] csr_src = CSR_op_ID[2] ? immediate_ID :
                         (hazard_rs1 ? rs1_data_hazard : rd_data1_GPR);
    reg [31:0] csr_wdata;
    // RS/RC 的无写入条件由 rs1 编号/zimm 决定，不能只看操作数是否为零。
    wire csr_has_source = CSR_op_ID[2] ? (immediate_ID[4:0] != 0) : (rs1_addr_ID != 0);
    wire csr_we = rst_n && valid_out_ID && CSR_en_ID && !stall &&
                  ((CSR_op_ID[1:0] == 2'b01) || csr_has_source);

    always @(*) begin
        case (CSR_op_ID[1:0])
            2'b01: csr_wdata = csr_src;
            2'b10: csr_wdata = csr_rdata | csr_src;
            2'b11: csr_wdata = csr_rdata & ~csr_src;
            default: csr_wdata = csr_rdata;
        endcase
    end

    // 只在当前 EX 指令有效且可以推进时接受。EX 指令本身继续完成，
    // 年轻指令由 flush_ID/flush_IF 取消。CSR 配置及 MRET 拍不同时进入中断，
    // 下一条指令即可观察新使能配置，避免两个不同的状态更新在同沿竞争。
    assign irq_accept = rst_n && irq_request && !stall && valid_out_ID &&
                        !CSR_en_ID && !Mret_ID;
    assign mret_commit = rst_n && valid_out_ID && Mret_ID && !stall;
    wire [31:0] actual_next_pc = J_taken ? J_pc :
                               ((ENABLE_DUAL != 0 && b_valid_ID) ? pc_ID + 32'd8 : pc_4_ID);
    assign irq_resume_pc = (predict_correct && valid_out_IF) ? pc_IF : actual_next_pc;

    CSR u_CSR (
        .clk(clk), .rst_n(rst_n), .stall(stall),
        .mret_commit(mret_commit), .CSR_addr(CSR_addr_ID),
        .CSR_we(csr_we), .CSR_in(csr_wdata), .timer_irq(timer_irq),
        .irq_accept(irq_accept), .irq_resume_pc(irq_resume_pc),
        .irq_entry_pc(irq_entry_pc), .mret_target_pc(mret_target_pc),
        .irq_request(irq_request), .CSR_out(csr_rdata)
    );

    //========================================================================


    //======================================core===================================
    // ---------------------pc--------------------------
    // 预测结果pc
    always @(posedge clk) begin
        if(!rst_n | flush_IF)begin
            if_predict_PC <= 0;
            pc_predict_PC <= 0;
        end

        else if(stall)begin
            if_predict_PC <= if_predict_PC;
            pc_predict_PC <= pc_predict_PC;
        end

        else begin
            if_predict_PC <= J_predict;
            pc_predict_PC <= pc_predict;
        end
    end

    generate if (ENABLE_DUAL == 0) begin : g_single_fetch
    PC u_PC(
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .load_pc_en (load_pc_en ),
        .load_pc    (load_pc    ),
        .stall      (stall_pc      ),
        .valid_out  (valid_out_pc  ),
        .pc         (pc         )
    );
    end else begin : g_dual_fetch
        assign valid_out_pc = rst_n;
        acore_fetch_queue u_fetch (
            .clk(clk), .rst_n(rst_n), .redirect(flush_IF), .redirect_pc(load_pc),
            .prediction(J_predict), .prediction_pc(pc_predict), .request_pc(pc),
            .consume((stall_ID || flush_ID || !valid_out_IF) ? 2'd0 : (pair_IF ? 2'd2 : 2'd1)),
            .valid(valid_out_IF), .second_valid(second_valid_IF),
            .head_pc(pc_IF), .head_instruction(instruction), .second_instruction(instruction_b),
            .head_prediction(head_prediction), .head_prediction_pc(head_prediction_pc)
        );
        assign pc_4_IF = pc_IF + 32'd4;
    end endgenerate
    
    //-------------------state1-IF-----------------------
    // PC.valid_out 现在是**组合**信号（与 PC 同拍）：复位/冲刷时为 0，其余为 1。
    //   它描述的是"本拍发出的取指是否有意义"，交给 ROM 采成 IF/ID 的 valid。
    //   以前它是寄存器，复位后滞后一拍，导致复位释放那一拍取到的地址 0 指令被丟掉。
    assign valid_in_IF = valid_out_pc;


    // localparam BR_BEQ  = 3'h0; // 3'b000, 相等则跳转
    // localparam BR_BNE  = 3'h1; // 3'b001, 不相等则跳转
    // localparam BR_BLT  = 3'h4; // 3'b100, 有符号数小于则跳转
    // localparam BR_BGE  = 3'h5; // 3'b101, 有符号数大于等于则跳转
    // localparam BR_BLTU = 3'h6; // 3'b110, 无符号数小于则跳转 (zero-extends)
    // localparam BR_BGEU = 3'h7; // 3'b111, 无符号数大于等于则跳转 (zero-extends)

    // 分支条件：bit0 为 1 的类型对 ALU 比较结果取反
    wire branch_cond  = out_comb_EX[0] ^ Branch_type_ID[0];
    wire branch_taken = Branch_ID & branch_cond & ~stall;

    // 跳转无条件
    wire jump_taken = Jump_ID & ~stall;

    // 分支目标地址
    wire [31:0] branch_target = pc_ID + immediate_ID;

    // 表示真实跳转
    assign J_taken = branch_taken | jump_taken;
    assign J_pc = jump_taken ? {out_comb_EX[31:1], 1'b0} : branch_target;

    // 判断预测是否正确
    assign predict_correct = (J_taken == if_predict_IF) & ((J_pc == pc_predict_IF) | !if_predict_IF);

    // 送到 PC
    // 
    assign load_pc_en = mret_commit | irq_accept | J_predict | !predict_correct;
    assign load_pc    = mret_commit ? mret_target_pc :
                        irq_accept ? irq_entry_pc :
                        predict_correct ? pc_predict :
                        ~J_taken ? pc_4_ID : J_pc;

    // 预测结果IF
    always @(posedge clk) begin
        if(!rst_n | flush_IF)begin
            if_predict_IF <= 0;
            pc_predict_IF <= 0;
        end

        else if(stall)begin
            if_predict_IF <= if_predict_IF;
            pc_predict_IF <= pc_predict_IF;
        end

        else begin
            if_predict_IF <= (ENABLE_DUAL != 0) ? (valid_out_IF && head_prediction) : if_predict_PC;
            pc_predict_IF <= (ENABLE_DUAL != 0) ? head_prediction_pc : pc_predict_PC;
        end        
    end

    generate if (ENABLE_DUAL == 0) begin : g_single_rom
    assign second_valid_IF = 1'b0;
    assign instruction_b = 32'h00000013;
    assign head_prediction = 1'b0;
    assign head_prediction_pc = 32'b0;
    ROM u_ROM(
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .flush       (flush_IF       ),
        .stall       (stall_IF       ),
        .pc_in       (pc       ),
        .valid_in    (valid_in_IF    ),
        .pc_out      (pc_IF      ),
        .pc_4_out    (pc_4_IF    ),
        .valid_out   (valid_out_IF   ),
        .instruction (instruction )
    );
    end endgenerate
    
    
    //------------------state2-ID-----------------------
    assign valid_in_ID = valid_out_IF; 

    always @(posedge clk) begin
        if(!rst_n)begin
            pc_ID <= 0;
            pc_4_ID <= 0;
        end
        else if(stall_ID)begin
            pc_ID <= pc_ID;
            pc_4_ID <= pc_4_ID;
        end
        else begin
            pc_ID <= pc_IF;
            pc_4_ID <= pc_4_IF;
        end
    end

    decoder #(.ENABLE_DIV(ENABLE_DIV)) u_decoder(
        .instruction (instruction ),
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .valid_in    ((ENABLE_DUAL != 0 && stall_ID) ? valid_out_ID : valid_in_ID),
        .flush       (flush_ID       ),
        .stall       (stall_ID       ),
        
        .rs1_addr    (rs1_addr_ID    ), 
        .rs2_addr    (rs2_addr_ID    ), 
        .rd_addr     (rd_addr_ID     ), 
        .RegWrite    (RegWrite_ID    ), 
        .MemRead     (MemRead_ID     ), 
        .MemWrite    (MemWrite_ID    ), 
        .MemSize     (MemSize_ID     ), 
        .MemUnsigned (MemUnsigned_ID ), 
        .wb_type     (wb_type_ID     ),  
        .ALUen       (ALUen_ID       ),  
        .ALUSrc1     (ALUSrc1_ID     ),  
        .ALUSrc2     (ALUSrc2_ID     ),  
        .ALUOp       (ALUOp_ID       ),  
        .DivOp       (DivOp_ID       ),
        .CSR_en      (CSR_en_ID      ),
        .CSR_op      (CSR_op_ID      ),
        .CSR_addr    (CSR_addr_ID    ),
        .Mret        (Mret_ID        ),
        .Branch      (Branch_ID      ),  
        .Branch_type (Branch_type_ID ),  
        .Jump        (Jump_ID        ),  
        .immediate   (immediate_ID   ), 
        .valid_out   (valid_out_ID   )
    );

    

    //------------------state3-EX---------------------
    
    // 流水线存储下来的目的寄存器地址/控制信号，同时也是后续 冒险检测/前递 的支点
    always @(posedge clk) begin
        if(!rst_n)begin
            rd_addr_EX_reg <= 5'b0;
            RegWrite_EX <= 0;  
            wb_type_EX <= 0;          
        end

        // 上一级停顿，在下一级产生空泡
        else if(stall_ID)begin
            rd_addr_EX_reg <= 5'b0;
            RegWrite_EX <= 0;  
            wb_type_EX <= 0;    
        end
        else begin
            rd_addr_EX_reg <= rd_addr_ID;
            RegWrite_EX <= RegWrite_ID;
            wb_type_EX <= wb_type_ID;
        end   
    end

    // 流水线存储下来的 内存 相关的地址/控制信号 ，同时是load-use冒险检测的支点
    always @(posedge clk) begin
        if(!rst_n)begin
            MemRead_EX <= 0;
            MemWrite_EX <= 0;
            MemSize_EX <= 0;
            MemUnsigned_EX <= 0;
        end

        // 上一级停顿，在下一级产生空泡
        else if(stall_ID)begin
            MemRead_EX <= 0;
            MemWrite_EX <= 0;
            MemSize_EX <= 0;
            MemUnsigned_EX <= 0;

        end

        else begin
            MemRead_EX <= MemRead_ID;
            MemWrite_EX <= MemWrite_ID;
            MemSize_EX <= MemSize_ID;
            MemUnsigned_EX <= MemUnsigned_ID;
        end
    end

    // 流水线存储下来的立即数，LUI：直接载入寄存器;还有PC+4
    always @(posedge clk) begin
        if(!rst_n)begin
            imm_EX <= 0;
            pc_EX <= 0;
            pc_4_EX <= 0;
        end

        // 上一级停顿，在下一级产生空泡
        else if(stall_ID)begin
            imm_EX <= 0;
            pc_EX <= 0;
            pc_4_EX <= 0;
        end

        else begin
            imm_EX <= immediate_ID;
            pc_EX <= pc_ID;
            pc_4_EX <= pc_4_ID;
        end
    end

    // EX/MEM：store 数据（rs2）—— 必须在 EX 拍末锁存。
    //   GPR 读的地址 rs2_addr_ID 属于 EX 那条指令（T-1 拍译码），
    //   而内存写发生在下一拍，直接用组合值会写成"下一条指令的 rs2"。
    //   这和前递无关：前递修的是"值旧"，这里错的是"属于哪条指令"。
    //   将来加前递时，把采样源换成转发后的 rs2 值即可，这一级寄存器保留。
    
    always @(posedge clk) begin
        if(!rst_n) rd_data2_EX <= 32'b0;
        else       rd_data2_EX <= (hazard_rs2) ? rs2_data_hazard : rd_data2_GPR;
    end


    // ALUSrc1,数据选择器信号，选择第一个操作数来源，选择1说明来自PC 
    // ALUSrc2,数据选择器信号，选择第二个操作数来源，选择1说明来自寄存器
    assign oprand1_EX = ALUSrc1_ID ? pc_ID : 
                        (hazard_rs1) ? rs1_data_hazard : rd_data1_GPR;
    assign oprand2_EX = ~ALUSrc2_ID ? immediate_ID :
                        (hazard_rs2) ? rs2_data_hazard : rd_data2_GPR;

    // 乘除法等待期间保持 PC、IF/ID 和 ID/EX，EX/MEM 每拍注入空泡，
    // 年老指令仍可完成访存和写回。等待 load-use 冒险解除后才能启动，
    // 保证 IP 第一次采样时拿到正确的前递数据。
    wire mul_start = mul_instruction && !load_stall && !mul_busy;
    wire div_start = div_instruction && !load_stall && !div_busy;
    assign stall = load_stall || (mul_instruction && !mul_ready) || (div_instruction && !div_ready);

    multiply_unit #(.PIPE_STAGES(MUL_PIPE_STAGES)) u_multiply_unit (
        .clk(clk), .rst_n(rst_n), .start(mul_start),
        .operation(ALUOp_ID[1:0]), .rs1(oprand1_EX), .rs2(oprand2_EX),
        .busy(mul_busy), .ready(mul_ready), .result(mul_result)
    );

    // 使用生成条件而非运行时屏蔽，关闭后不会保留除法器寄存器和减法数据通路。
    generate
        if (ENABLE_DIV != 0) begin : g_divider
            divide_unit u_divide_unit (
                .clk(clk), .rst_n(rst_n), .start(div_start),
                .operation(DivOp_ID), .rs1(oprand1_EX), .rs2(oprand2_EX),
                .busy(div_busy), .ready(div_ready), .result(div_result)
            );
        end else begin : g_no_divider
            assign div_busy = 1'b0;
            assign div_ready = 1'b0;
            assign div_result = 32'b0;
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            mul_select_EX <= 0;
            mul_result_EX <= 0;
            div_select_EX <= 0;
            div_result_EX <= 0;
            csr_select_EX <= 0;
            csr_result_EX <= 0;
        end else begin
            mul_select_EX <= mul_instruction && !stall_ID;
            div_select_EX <= div_instruction && !stall_ID;
            csr_select_EX <= valid_out_ID && CSR_en_ID && !stall_ID;
            if (valid_out_ID && CSR_en_ID && !stall_ID)
                csr_result_EX <= csr_rdata;
            if (mul_instruction && !stall_ID)
                mul_result_EX <= mul_result;
            if (div_instruction && !stall_ID)
                div_result_EX <= div_result;
        end
    end
    // 乘除法结果复用已有的 ALU 结果前递和 WB_ALU 写回通道。
    assign out_EX = csr_select_EX ? csr_result_EX :
                    div_select_EX ? div_result_EX : mul_select_EX ? mul_result_EX : alu_out_EX;
    assign en_EX = ALUen_ID && !mul_instruction && !div_instruction;
    assign opcode_EX = ALUOp_ID;
    assign valid_in_EX = valid_out_ID; 
    ALU u_ALU(
        .clk       (clk       ),
        .opcode    (opcode_EX    ),
        .oprand1   (oprand1_EX   ),
        .oprand2   (oprand2_EX   ),
        .en        (en_EX        ),
        .flush     (flush_EX     ),
        .valid_in  (valid_in_EX  ),
        .stall     (stall_EX     ),
        .out       (alu_out_EX   ),
        .out_comb  (out_comb_EX  ),
        .valid_out (valid_out_EX )
    );
    

    //--------------------IO port(MEM同级)-------------------------
    assign addr_EX = out_EX;
    assign sel_dev = (addr_EX[31:16] == 3); // 选择外设
    assign dev_size = MemSize_EX;           // 数据大小
    assign dev_we = sel_dev & MemWrite_EX;  // 写外设使能
    assign dev_re = sel_dev & MemRead_EX;   // 读外设使能

    // 外设地址32位输出
    assign dev_addr_wr = addr_EX;            
    assign dev_addr_rd = addr_EX;    

    // 外设数据
    
    assign dev_wdata = rd_data2_EX;

    always @(posedge clk) begin
        if(!rst_n)begin
            sel_dev_MEM <= 0;
        end
        else begin
            sel_dev_MEM <= dev_re;
        end
    end

    //--------------------state4-MEM-----------------------
    // 流水线存储下来的 目的寄存器地址/数据/控制信号，同时也是后续 冒险检测/前递 的支点
    always @(posedge clk) begin
        if(!rst_n)begin
            rd_addr_MEM_reg <= 5'b0;
            RegWrite_MEM <= 1'b0;
            ALU_OUT_MEM <= 32'b0;
            wb_type_MEM <= 0;
        end
            
        else begin
            rd_addr_MEM_reg <= rd_addr_EX_reg;
            RegWrite_MEM <= RegWrite_EX;
            ALU_OUT_MEM <= out_EX;
            wb_type_MEM <= wb_type_EX;
        end  
    end

    // 流水线存储下来的立即数，LUI：直接载入寄存器
    always @(posedge clk) begin
        if(!rst_n)begin
            imm_MEM <= 0;
            pc_4_MEM <= 0;
        end
        else begin
            imm_MEM <= imm_EX;
            pc_4_MEM <= pc_4_EX;
        end
    end

    assign sel_ram = (addr_EX[31:16] == 1);     // 选择内存

    assign MemSize_MEM = MemSize_EX;
    assign MemUnsigned_MEM = MemUnsigned_EX;

    // 内存读写使能
    assign wr_en_MEM = MemWrite_EX & sel_ram;
    assign rd_en_MEM = MemRead_EX & sel_ram;

    // 内存读写地址
    assign wr_addr_MEM = addr_EX[15:0];
    assign rd_addr_MEM = addr_EX[15:0];

    // 内存写数据
    assign wr_data_MEM = rd_data2_EX;

    // 64KB内存,addr:0-65535 
    memory #(
        .DATA_WIDTH(8),
        .ADDR_WIDTH(16),
        .DUAL_IMAGE(ENABLE_DUAL)
    ) u_memory(
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .MemSize     (MemSize_MEM     ),
        .MemUnsigned (MemUnsigned_MEM ),
        .wr_en       (wr_en_MEM       ),
        .wr_addr     (wr_addr_MEM     ),
        .wr_data     (wr_data_MEM     ),
        .rd_en       (rd_en_MEM       ),
        .rd_addr     (rd_addr_MEM     ),
        .rd_data     (rd_data_MEM     )
    );

    assign bus_err = (!(sel_dev | sel_ram)) & (MemRead_EX | MemWrite_EX);  // 即没有映射内存也没有映射外设

    //-------------------state5-WB---------------------

    assign rd_addr1_GPR = rs1_addr_ID;
    assign rd_addr2_GPR = rs2_addr_ID;

    // 写回路径
    localparam WB_ALU = 2'b00; 
    localparam WB_MEM = 2'b01; 
    localparam WB_IMM = 2'b10; 
    localparam WB_PC4 = 2'b11; 

    assign wr_data_WB = sel_dev_MEM ? dev_rdata : // 添加一个从外设读取数据进入寄存器的通道
                            (wb_type_MEM == WB_ALU) ? ALU_OUT_MEM : 
                            (wb_type_MEM == WB_MEM) ? rd_data_MEM : // 如果是非映射的区域最后还是会从内存读取
                            (wb_type_MEM == WB_IMM) ? imm_MEM:
                            (wb_type_MEM == WB_PC4) ? pc_4_MEM : pc_4_MEM;
    assign wr_en_WB = RegWrite_MEM;
    assign wr_addr_WB = rd_addr_MEM_reg;

    GPR_matrix #(.ENABLE_DUAL(ENABLE_DUAL)) u_GPR_matrix(
        .clk      (clk      ),
        .rst_n    (rst_n    ),
        .wr_en    (wr_en_WB    ),
        .wr_addr  (wr_addr_WB  ),
        .wr_data  (wr_data_WB  ),
        .rd_addr1 (rd_addr1_GPR ),
        .rd_addr2 (rd_addr2_GPR ),
        .rd_data1 (rd_data1_GPR ),
        .rd_data2 (rd_data2_GPR ),
        .wr_en_b(b_valid_MEM), .wr_addr_b(b_rd_MEM), .wr_data_b(b_result_MEM),
        .rd_addr3(b_rs1_ID), .rd_addr4(b_rs2_ID),
        .rd_data3(b_gpr1), .rd_data4(b_gpr2)
    );

    // --------------flush / stall Logic--------------
    assign flush_ID = (!predict_correct | irq_accept | mret_commit) & ~stall;
    assign flush_IF = (!predict_correct | irq_accept | mret_commit) & ~stall;

    assign flush_EX = 1'b0;         // ALU 不需要冲刷：错路径指令在 ID/EX 就已变成 NOP


    assign stall_pc = stall;
    assign stall_IF = stall;
    assign stall_ID = stall;
    assign stall_EX = 1'b0;

    generate if (ENABLE_DUAL == 0) begin : g_single_hazard
    hazard_detection_unit u_hazard_detection_unit(
        .wb_type_EX      (wb_type_EX      ),
        .rs1_addr_ID     (rs1_addr_ID     ),
        .rs2_addr_ID     (rs2_addr_ID     ),
        .rd_addr_EX      (rd_addr_EX_reg      ),
        .rd_addr_MEM     (rd_addr_MEM_reg     ),
        .ALU_OUT_EX      (out_EX      ),
        .imm_EX          (imm_EX          ),
        .pc_4_EX         (pc_4_EX         ),
        .wr_data_WB_comb (wr_data_WB      ),
        .stall           (load_stall      ),
        .hazard_rs1      (hazard_rs1      ),
        .hazard_rs2      (hazard_rs2      ),
        .rs1_data        (rs1_data_hazard        ),
        .rs2_data        (rs2_data_hazard        )
    );
    end else begin : g_dual_hazard
        acore_forward u_forward (
            .a_ex_we(RegWrite_EX), .a_ex_rd(rd_addr_EX_reg),
            .a_ex_ready(wb_type_EX != WB_MEM),
            .a_ex_data((wb_type_EX == WB_IMM) ? imm_EX : (wb_type_EX == WB_PC4) ? pc_4_EX : out_EX),
            .b_ex_we(b_valid_EX), .b_ex_rd(b_rd_EX), .b_ex_data(b_result_EX),
            .a_wb_we(wr_en_WB), .a_wb_rd(wr_addr_WB), .a_wb_data(wr_data_WB),
            .b_wb_we(b_valid_MEM), .b_wb_rd(b_rd_MEM), .b_wb_data(b_result_MEM),
            .rs1(rs1_addr_ID), .rs2(rs2_addr_ID), .rs3(b_valid_ID ? b_rs1_ID : 5'd0),
            .rs4(b_valid_ID ? b_rs2_ID : 5'd0),
            .hit1(hazard_rs1), .hit2(hazard_rs2), .hit3(b_hit1), .hit4(b_hit2),
            .data1(rs1_data_hazard), .data2(rs2_data_hazard), .data3(b_forward1), .data4(b_forward2),
            .stall(load_stall)
        );
    end endgenerate

    //---------------branch_predictor---------------
    assign upd_pc = pc_ID;
    assign upd_type = {Jump_ID, ALUSrc1_ID};
    assign upd_en = (Branch_ID | Jump_ID) & ~stall;
    assign upd_taken = branch_taken | jump_taken;
    assign upd_target_pc = jump_taken ? out_comb_EX : branch_target;

    branch_predictor u_branch_predictor(
        .clk           (clk           ),
        .rst_n         (rst_n         ),
        .stall         (stall         ),
        .pc            (pc            ),

        .if_predict    (J_predict     ),    // 输出：1：预测需要跳转
        .pc_predict    (pc_predict    ),    // 输出：预测pc
        
        .upd_pc        (upd_pc        ),
        .upd_type      (upd_type      ),
        .upd_en        (upd_en        ),
        .upd_taken     (upd_taken     ),
        .upd_target_pc (upd_target_pc )
    );
    

    // synthesis translate_off
    always @(posedge clk) if (rst_n && ENABLE_DUAL != 0) begin
        if (b_valid_ID && (!valid_out_ID || MemRead_ID || MemWrite_ID || Branch_ID || Jump_ID ||
                          CSR_en_ID || Mret_ID || mul_instruction || div_instruction))
            $fatal(1, "Invalid dual-issue packet");
        if (b_valid_ID && rd_addr_ID != 0 && rd_addr_ID == b_rd_ID)
            $fatal(1, "Same-packet WAW conflict");
    end
    // synthesis translate_on
    //===============================================================
endmodule
