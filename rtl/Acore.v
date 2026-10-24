module Acore(
    input clk,
    input rst_n,

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
    wire Branch_ID;
    wire [2:0]Branch_type_ID;
    wire Jump_ID;
    wire [31:0]immediate_ID;
    wire valid_out_ID;

    reg [31:0]pc_ID;
    reg [31:0]pc_4_ID;

    //------------stage3-EX-----------------
    wire [3:0]opcode_EX;
    wire [31:0]oprand1_EX;
    wire [31:0]oprand2_EX;
    wire en_EX;
    wire flush_EX;
    wire valid_in_EX;
    wire stall_EX;
    wire [31:0]out_EX;
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
    reg [31:0]pc_EX;
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
    wire stall;
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

    PC u_PC(
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .load_pc_en (load_pc_en ),
        .load_pc    (load_pc    ),
        .stall      (stall_pc      ),
        .valid_out  (valid_out_pc  ),
        .pc         (pc         )
    );
    
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
    assign J_pc = jump_taken ? out_comb_EX : branch_target;

    // 判断预测是否正确
    assign predict_correct = (J_taken == if_predict_IF) & ((J_pc == pc_predict_IF) | !if_predict_IF);

    // 送到 PC
    // 
    assign load_pc_en = J_predict | !predict_correct; 
    assign load_pc    = predict_correct ? pc_predict : 
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
            if_predict_IF <= if_predict_PC;
            pc_predict_IF <= pc_predict_PC;
        end        
    end

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

    decoder u_decoder(
        .instruction (instruction ),
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .valid_in    (valid_in_ID    ),
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

    assign en_EX = ALUen_ID;
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
        .out       (out_EX       ),
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
        .ADDR_WIDTH(16)
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

    GPR_matrix u_GPR_matrix(
        .clk      (clk      ),
        .rst_n    (rst_n    ),
        .wr_en    (wr_en_WB    ),
        .wr_addr  (wr_addr_WB  ),
        .wr_data  (wr_data_WB  ),
        .rd_addr1 (rd_addr1_GPR ),
        .rd_addr2 (rd_addr2_GPR ),
        .rd_data1 (rd_data1_GPR ),
        .rd_data2 (rd_data2_GPR )
    );

    // --------------flush / stall Logic--------------
    assign flush_ID = !predict_correct & ~stall;       //  !predict_correct & ~stall; // 预测错误：冲刷
    assign flush_IF = !predict_correct & ~stall;      //  !predict_correct & ~stall;  // 预测错误：冲刷

    assign flush_EX = 1'b0;         // ALU 不需要冲刷：错路径指令在 ID/EX 就已变成 NOP


    assign stall_pc = stall;
    assign stall_IF = stall;
    assign stall_ID = stall;
    assign stall_EX = 1'b0;

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
        .stall           (stall           ),
        .hazard_rs1      (hazard_rs1      ),
        .hazard_rs2      (hazard_rs2      ),
        .rs1_data        (rs1_data_hazard        ),
        .rs2_data        (rs2_data_hazard        )
    );

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
    

    //===============================================================
endmodule
