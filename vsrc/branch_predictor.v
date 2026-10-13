module branch_predictor#(
    parameter IDX_BITS = 6,         // 查找表的位数
    parameter IDX_NUM = (1<<IDX_BITS),
    parameter PC_HI    = 14         // ROM 32KB → pc[14:0]
)(
    input clk,
    input rst_n,
    input stall,

    // 取指，预测
    input [31:0]pc,
    output reg if_predict,
    output reg [31:0]pc_predict,

    // 训练
    input [31:0]upd_pc,             // 跳转/分支指令属于哪个pc
    input [1:0]upd_type,            // 00:B  11:JAL  10:JALR = {Jump_ID, ALUSrc1_ID}
    input upd_en,                   // 是否为跳转指令
    input upd_taken,                // 是否真的执行跳转/分支          
    input [31:0]upd_target_pc       // 跳转/分支后的目标PC，Acore中位于根植于ID/EX寄存器
);
    localparam STRONG_J  = 2'b00;
    localparam WEAK_J    = 2'b01;
    localparam WEAK_NJ   = 2'b10;
    localparam STRONG_NJ = 2'b11;

    // BTB查找表
    wire [IDX_BITS-1:0]idx = pc[2+IDX_BITS-1:2];            // 预测时的索引
    wire [IDX_BITS-1:0]upd_idx = upd_pc[2+IDX_BITS-1:2];    // 更新时的索引
    reg [PC_HI-8:0]tag[0:IDX_NUM-1];
    reg [1:0]B_type[0:IDX_NUM-1];
    reg [31:0]PC_N[0:IDX_NUM-1];
    reg [1:0]strength_cnt[0:IDX_NUM-1];
    reg valid[0:IDX_NUM-1];


    // 更新预测矩阵
    integer i;
    always @(posedge clk) begin
        if(!rst_n)begin
            for(i=0;i<IDX_NUM;i++)begin
                tag[i] <= 0;
                B_type[i] <= 0;
                PC_N[i] <= 0;
                strength_cnt[i] <= WEAK_NJ;
                valid[i] <= 0;
            end
        end

        else if(stall)begin
          
        end

        // 分支/跳转指令，更新预测矩阵
        else if(upd_en)begin
            // 有效的跳转
            if(upd_taken)begin
                tag[upd_idx]    <= upd_pc[PC_HI:8];
                B_type[upd_idx] <= upd_type;
                PC_N[upd_idx]   <= upd_target_pc;
                valid[upd_idx]  <= 1;

                case(strength_cnt[upd_idx])
                    STRONG_J:strength_cnt[upd_idx]  <= STRONG_J;
                    WEAK_J:strength_cnt[upd_idx]    <= STRONG_J;
                    WEAK_NJ:strength_cnt[upd_idx]   <= WEAK_J;
                    STRONG_NJ:strength_cnt[upd_idx] <= WEAK_NJ;
                    default:strength_cnt[upd_idx]   <= strength_cnt[upd_idx];
                endcase
            end

            // 非有效的跳转
            else begin
                tag[upd_idx]    <= upd_pc[PC_HI:8];
                B_type[upd_idx] <= upd_type;
                PC_N[upd_idx]   <= PC_N[upd_idx];
                valid[upd_idx]  <= 1;
                 
                case(strength_cnt[upd_idx])
                    STRONG_J:strength_cnt[upd_idx]  <= WEAK_J;
                    WEAK_J:strength_cnt[upd_idx]    <= WEAK_NJ;
                    WEAK_NJ:strength_cnt[upd_idx]   <= STRONG_NJ;
                    STRONG_NJ:strength_cnt[upd_idx] <= STRONG_NJ;
                    default:strength_cnt[upd_idx]   <= strength_cnt[upd_idx];
                endcase
                                  
            end
        end

        // 非有效跳转指令，不操作
        else begin
            
        end
    end

    // 预测部分
    always @(*) begin
        if(valid[idx] & (tag[idx] == pc[PC_HI:8]) & (strength_cnt[idx] < WEAK_NJ))begin
            if_predict = 1;
            pc_predict = PC_N[idx];
        end

        else begin
            if_predict = 0;
            pc_predict = 0;
        end
    end


endmodule
