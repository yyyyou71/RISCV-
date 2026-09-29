module decoder(
    input [31:0]instruction,
    input clk,

    input valid_in,
    input flush,
    input stall,

    output reg [4:0]rs1_addr,
    output reg [4:0]rs2_addr,
    output reg [4:0]rd_addr,

    output reg RegWrite,
    output reg MemRead,
    output reg MemWrite,
    output reg [1:0]MemSize,      // 访存宽度：00=字节 01=半字 10=字（load/store 共用）
    output reg      MemUnsigned,  // 1=零扩展（LBU/LHU）；LW 和 store 都是 don't care
    output reg [1:0]wb_type, 
    output reg ALUen,
    output reg ALUSrc1, // 数据选择器信号，选择第一个操作数来源，选择1说明来自PC 
    output reg ALUSrc2, // 数据选择器信号，选择第二个操作数来源,选择1说明来自寄存器
    output reg [3:0]ALUOp, // alu控制信号
    output reg Branch,
    output reg [2:0]Branch_type, // 跳转种类
    output reg Jump,
    
    output reg [31:0]immediate,

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

    // 分支指令的 funct3 编码 (BranchType)
    localparam BR_BEQ  = 3'h0; // 3'b000, 相等则跳转
    localparam BR_BNE  = 3'h1; // 3'b001, 不相等则跳转
    localparam BR_BLT  = 3'h4; // 3'b100, 有符号数小于则跳转
    localparam BR_BGE  = 3'h5; // 3'b101, 有符号数大于等于则跳转
    localparam BR_BLTU = 3'h6; // 3'b110, 无符号数小于则跳转 (zero-extends)
    localparam BR_BGEU = 3'h7; // 3'b111, 无符号数大于等于则跳转 (zero-extends)

    // 写回路径
    localparam WB_ALU = 2'b00; 
    localparam WB_MEM = 2'b01; 
    localparam WB_IMM = 2'b10; 
    localparam WB_PC4 = 2'b11; 

    // 是否载入流水线标志位
    always @(posedge clk) begin
        if(flush)
            valid_out <= 1'b0;
        else if(stall)
            valid_out <= valid_out;
        else
            valid_out <= valid_in;
    end

    wire if_R = (instruction[6:0] == 7'b0110011);

    wire if_I_A = (instruction[6:0] == 7'b0010011);
    wire if_I_L = (instruction[6:0] == 7'b0000011);
    wire if_I_J = (instruction[6:0] == 7'b1100111);

    wire if_S = (instruction[6:0] == 7'b0100011);
    wire if_B = (instruction[6:0] == 7'b1100011);

    wire if_U = (instruction[6:0] == 7'b0110111);
    wire if_U_A = (instruction[6:0] == 7'b0010111);

    wire if_J = (instruction[6:0] == 7'b1101111);
    
    wire if_e = (instruction[6:0] == 7'b1110011 | instruction[6:0] == 7'b0001111);

    wire [9:0] type_flag;
    assign type_flag = {if_e, if_J, if_U_A, if_U, if_B, if_S, if_I_J, if_I_L, if_I_A, if_R};
    
    wire [2:0]funct3 = instruction[14:12];
    wire [6:0]funct7 = instruction[31:25];

    // 各种输出信号
    always @(posedge clk) begin
        if(stall)begin
            RegWrite <= RegWrite;
            MemRead <= MemRead;
            MemWrite <= MemWrite; 
             
            MemSize <= MemSize;
            MemUnsigned <= MemUnsigned;
            ALUSrc2 <= ALUSrc2;
            Branch <= Branch;
            Jump <= Jump;
            immediate <= immediate;
            ALUOp <= ALUOp;
            ALUen <= ALUen;
            wb_type <= wb_type;
            ALUSrc1 <= ALUSrc1;
            Branch_type <= Branch_type;

            rs1_addr <= rs1_addr;
            rs2_addr <= rs2_addr;
            rd_addr <= rd_addr;        
        end

        else begin
            // MemSize / MemUnsigned 只有 load 和 store 两个桶会用到，
            // 其余桶一律保持（don't care → 不动，省翻转）。
            MemSize     <= MemSize;
            MemUnsigned <= MemUnsigned;

            case (type_flag)            
                10'b00_0000_0001: begin   // if_R
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_ALU;
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 1;
                    Branch <= 0;
                    Jump <= 0;
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= instruction[24:20];
                    rd_addr <= instruction[11:7]; 
                    case (funct3)
                        3'h0: begin
                            if (funct7 == 7'h0)
                                ALUOp <= OP_ADD;   
                            else
                                ALUOp <= OP_SUB;   
                        end
                        3'h1: ALUOp <= OP_SLL;     
                        3'h2: ALUOp <= OP_SLT;     
                        3'h3: ALUOp <= OP_SLTU;    
                        3'h4: ALUOp <= OP_XOR;    
                        3'h5: begin
                            if (funct7 == 7'h0)
                                ALUOp <= OP_SRL;   
                            else
                                ALUOp <= OP_SRA;   
                        end
                        3'h6: ALUOp <= OP_OR;      
                        3'h7: ALUOp <= OP_AND;     
                        default: ALUOp <= OP_ADD;  
                    endcase
                end  
                10'b00_0000_0010: begin   // if_I_A
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_ALU;
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {{20{instruction[31]}}, instruction[31:20]};
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7]; 
                    case (funct3)
                        3'h0: ALUOp <= OP_ADD;
                        3'h1: ALUOp <= OP_SLL;
                        3'h2: ALUOp <= OP_SLT;
                        3'h3: ALUOp <= OP_SLTU;
                        3'h4: ALUOp <= OP_XOR;
                        3'h5: begin
                            if(funct7 == 7'h0)
                                ALUOp <= OP_SRL;
                            else
                                ALUOp <= OP_SRA;
                        end
                        3'h6: ALUOp <= OP_OR;
                        3'h7: ALUOp <= OP_AND;
                        default: ALUOp <= OP_ADD;
                    endcase
                end  
                10'b00_0000_0100: begin   // if_I_L
                    RegWrite <= 1;
                    MemRead <= 1;
                    MemWrite <= 0;
                    MemSize <= funct3[1:0];     // 宽度就在 funct3 低两位：00=字节 01=半字 10=字
                    MemUnsigned <= funct3[2];   // funct3 的 bit2 就是零扩展位（LBU/LHU=1）
                    wb_type <= WB_MEM;
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {{20{instruction[31]}}, instruction[31:20]};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7]; 
                end  
                10'b00_0000_1000: begin   // if_I_J (JALR)
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_PC4;        // 写回链接值 PC+4（不是 ALU 算的跳转目标）
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 0;
                    Branch <= 0;
                    Jump <= 1;
                    immediate <= {{20{instruction[31]}}, instruction[31:20]};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7]; 
                end  
                10'b00_0001_0000: begin   // if_S
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 1;
                    MemSize <= funct3[1:0];     // SB/SH/SW 的宽度（MemUnsigned 对 store 无意义 → 保持）
                    wb_type <= wb_type;       // 不写回 → 下游不用 → 保持
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {{21{instruction[31]}}, instruction[30:25], instruction[11:7]};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= instruction[24:20];
                    rd_addr <= rd_addr; 
                end  
                10'b00_0010_0000: begin   // if_B
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= wb_type;       // 不写回 → 下游不用 → 保持
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 1;
                    Branch <= 1;
                    Jump <= 0;
                    immediate <= {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= instruction[24:20];
                    rd_addr <= rd_addr; 
                    case (funct3)
                        3'h0: begin                 // 等于跳转
                            ALUOp <= OP_EQ;
                            Branch_type <= BR_BEQ;
                        end  
                        3'h1: begin                 // 不等于跳转
                            ALUOp <= OP_EQ;
                            Branch_type <= BR_BNE;
                        end
                        3'h4: begin                 // 有符号小于跳转
                            ALUOp <= OP_SLT;
                            Branch_type <= BR_BLT;
                        end
                        3'h5: begin                 // 有符号大于等于跳转
                            ALUOp <= OP_SLT;
                            Branch_type <= BR_BGE;        
                        end
                        3'h6: begin                 // 无符号小于跳转
                            ALUOp <= OP_SLTU;
                            Branch_type <= BR_BLTU; 
                        end
                        3'h7: begin                 // 无符号大于等于跳转
                            ALUOp <= OP_SLTU;
                            Branch_type <= BR_BGEU;
                        end
                        default: begin
                            
                        end
                    endcase
                end  
                10'b00_0100_0000: begin   // if_U (LUI)
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_IMM;        // 写回立即数本身
                    ALUSrc1 <= ALUSrc1;       // ALUen=0 → 下游不用 → 保持
                    
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {instruction[31:12],12'b0};
                    ALUOp <= ALUOp;           // ALUen=0 → 保持
                    ALUen <= 0;
                    ALUSrc2 <= ALUSrc2;       // ALUen=0 → 保持

                    rs1_addr <= rs1_addr;
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7]; 
                end  
                10'b00_1000_0000: begin   // if_U_A (AUIPC)
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_ALU;        // 写回 PC + imm，由 ALU 计算
                    ALUSrc1 <= 1;             // A 口取 PC（区别于 LUI！）
                    ALUSrc2 <= 0;             // B 口取立即数
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {instruction[31:12],12'b0};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;               // 必须开 ALU 才能做加法

                    rs1_addr <= rs1_addr;     // AUIPC 不读寄存器，地址 don't care
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7];
                end
                10'b01_0000_0000: begin   // if_J
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_PC4;        // 写回链接值 PC+4
                    ALUSrc1 <= ALUSrc1;       // ALUen=0 → 下游不用 → 保持
                    
                    ALUSrc2 <= ALUSrc2;       // ALUen=0 → 保持
                    Branch <= 0;
                    Jump <= 1;
                    immediate <= {{12{instruction[31]}},instruction[19:12],instruction[20],instruction[30:25],instruction[24:21],1'b0};
                    ALUOp <= ALUOp;           // ALUen=0 → 保持
                    ALUen <= 0;

                    rs1_addr <= rs1_addr;
                    rs2_addr <= rs2_addr;
                    rd_addr <= instruction[11:7];
                end  
                10'b10_0000_0000: begin   // if_e
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= wb_type;       // 不写回 → 保持
                    ALUSrc1 <= ALUSrc1;       // ALUen=0 → 保持
                    
                    ALUSrc2 <= ALUSrc2;       // ALUen=0 → 保持
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= 0;
                    ALUOp <= ALUOp;           // ALUen=0 → 保持
                    ALUen <= 0;

                    rs1_addr <= rs1_addr;
                    rs2_addr <= rs2_addr;
                    rd_addr <= rd_addr;
                end 
                default: begin
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= wb_type;       // 不写回 → 保持
                    ALUSrc1 <= ALUSrc1;       // ALUen=0 → 保持
                    
                    ALUSrc2 <= ALUSrc2;       // ALUen=0 → 保持
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= 0;
                    ALUOp <= ALUOp;           // ALUen=0 → 保持
                    ALUen <= 0;

                    rs1_addr <= rs1_addr;
                    rs2_addr <= rs2_addr;
                    rd_addr <= rd_addr;
                end
            endcase
        end
    end
    
endmodule
