module decoder(
    input [31:0]instruction,
    input clk,
    input rst_n,

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
    // 1100..1111 送到独立的多周期乘法单元，普通 ALU 不处理这些编码。
    localparam OP_MUL_BASE = 4'b1100;

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

    // 冲刷 / 复位：两者都是"向流水线注入一条 NOP"（清掉所有有副作用的使能）
    //   flush     : 分支/跳转在 EX 判定为 taken 的**同一拍**拉高，杀掉此刻正在译码的
    //               那条年轻指令。本设计取指与译码同拍（ROM 组合输出、无 IF/ID 寄存器），
    //               在途的只有这一条 → 冲一拍就够（经典五级要冲两拍）。
    //   !rst_n    : 上电/复位，让输出停在安全的 NOP 上
    //   !valid_in : ID 里装的是"无效指令" → 输出 NOP。有了它才有无条件的不变量
    //               「valid_out=0 ⟺ kill ⟺ 控制信号全 0」，下游 EX/MEM、MEM/WB
    //               因此不必再各带一个 valid 位。
    // 优先级：复位/冲刷 > stall（下面两个 always 块保持一致）
    wire kill = flush | ~rst_n | ~valid_in;

    // 是否载入流水线标志位
    always @(posedge clk) begin
        if(kill)
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
        if(stall && !kill)begin
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
            //  默认值：本条指令"用不到"的输出一律取确定的默认值。
            rs1_addr    <= 5'd0;
            rs2_addr    <= 5'd0;
            rd_addr     <= 5'd0;
            wb_type     <= WB_ALU;
            ALUSrc1     <= 1'b0;
            ALUSrc2     <= 1'b0;
            ALUOp       <= OP_ADD;
            MemSize     <= 2'b00;
            MemUnsigned <= 1'b0;
            Branch_type <= 3'd0;
            immediate   <= 32'd0;

            // 冲刷 = 注入 NOP：把选择子置 0（不匹配任何有效桶），自动落入下面的
            // default: 桶 → 所有有副作用的使能（RegWrite/MemWrite/**Jump**/**Branch**/
            // ALUen/MemRead）全部清零，其余信号取上方默认值。
            // 这样被冲掉的指令在 ID/EX 里就是完整的惰性 NOP，不会写坏寄存器/内存，
            // 更不会把 PC 跳到错误的地方。
            // 优先级与 valid_out 一致：kill（复位/冲刷）高于 stall。
            case (kill ? 10'b0 : type_flag)            
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
                    if (funct7 == 7'h01) begin
                        if (!funct3[2]) begin
                            ALUOp <= OP_MUL_BASE | {2'b00, funct3[1:0]};
                        end else begin
                            // 尚未实现 DIV/DIVU/REM/REMU，沿用未支持指令
                            // 不产生副作用的处理方式，避免误译码为逻辑指令。
                            // 当前处理器尚未接入非法指令异常。
                            RegWrite <= 0;
                            ALUen <= 0;
                            rd_addr <= 0;
                            rs1_addr <= 0;
                            rs2_addr <= 0;
                        end
                    end else begin
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
                    rd_addr <= instruction[11:7]; 
                end  
                10'b00_0001_0000: begin   // if_S
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 1;
                    MemSize <= funct3[1:0];     // SB/SH/SW 的宽度（MemUnsigned 对 store 无意义 → 默认 0）
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {{21{instruction[31]}}, instruction[30:25], instruction[11:7]};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= instruction[24:20];
                end  
                10'b00_0010_0000: begin   // if_B
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    ALUSrc1 <= 0;
                    
                    ALUSrc2 <= 1;
                    Branch <= 1;
                    Jump <= 0;
                    immediate <= {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0};
                    ALUen <= 1;

                    rs1_addr <= instruction[19:15];
                    rs2_addr <= instruction[24:20];
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
                            Branch <= 0;
                        end
                    endcase
                end  
                10'b00_0100_0000: begin   // if_U (LUI)
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_IMM;        // 写回立即数本身
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= {instruction[31:12],12'b0};
                    ALUen <= 0;               // 不用 ALU → ALUOp / ALUSrc1 / ALUSrc2 用默认值

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

                    rd_addr <= instruction[11:7];
                end
                10'b01_0000_0000: begin   // if_J
                    RegWrite <= 1;
                    MemRead <= 0;
                    MemWrite <= 0;
                    wb_type <= WB_PC4;        // 写回链接值 PC+4（不是 ALU 这个结果）
                    ALUSrc1 <= 1;             // A 口取 PC
                    ALUSrc2 <= 0;             // B 口取立即数
                    Branch <= 0;
                    Jump <= 1;
                    immediate <= {{12{instruction[31]}},instruction[19:12],instruction[20],instruction[30:25],instruction[24:21],1'b0};
                    ALUOp <= OP_ADD;
                    ALUen <= 1;               // 用 ALU 算跳转目标 PC+imm；结果→PC，不写回

                    rd_addr <= instruction[11:7];
                end  
                10'b10_0000_0000: begin   // if_e
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= 0;
                    ALUen <= 0;
                end 
                default: begin
                    RegWrite <= 0;
                    MemRead <= 0;
                    MemWrite <= 0;
                    Branch <= 0;
                    Jump <= 0;
                    immediate <= 0;
                    ALUen <= 0;
                end
            endcase
        end
    end
    
endmodule
