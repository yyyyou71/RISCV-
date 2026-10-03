module hazard_detection_unit(
    input [1:0]wb_type_EX,


    // 消费寄存器地址
    input [4:0]rs1_addr_ID,
    input [4:0]rs2_addr_ID,

    // 目的寄存器地址
    input [4:0]rd_addr_EX,
    input [4:0]rd_addr_MEM,

    //----目的寄存器数据来源-------
    // EX级
    input [31:0]ALU_OUT_EX,
    input [31:0]imm_EX,
    input [31:0]pc_4_EX,
    // MEM级
    input [31:0]wr_data_WB_comb,
    //--------------------------

    // 空泡触发使能
    output stall,
    // 冒险触发使能
    output reg hazard_rs1,
    output reg hazard_rs2,

    // 前递数据到对应端口
    output reg [31:0]rs1_data,
    output reg [31:0]rs2_data
);

    // 写回路径
    localparam WB_ALU = 2'b00; 
    localparam WB_MEM = 2'b01; 
    localparam WB_IMM = 2'b10; 
    localparam WB_PC4 = 2'b11;

    reg rs1_stall;
    reg rs2_stall;

    // rs1前递
    always @(*) begin
        if(rd_addr_EX == rs1_addr_ID)begin
            if(wb_type_EX == WB_MEM)begin
                rs1_stall = 1;
                hazard_rs1 = 1;
                rs1_data = 32'b0;
            end
            else begin
                rs1_stall = 0;
                hazard_rs1 = 1;
                case (wb_type_EX)
                    WB_ALU: rs1_data = ALU_OUT_EX;
                    WB_IMM: rs1_data = imm_EX;
                    WB_PC4: rs1_data = pc_4_EX;
                    default: rs1_data = 32'b0;
                endcase
            end
        end

        else if(rd_addr_MEM == rs1_addr_ID)begin
            rs1_stall = 0;
            hazard_rs1 = 1;
            rs1_data = wr_data_WB_comb;
        end

        else begin
            hazard_rs1 = 0;
            rs1_stall = 0;
            rs1_data = 32'b0;
        end
    end

    // rs2前递
    always @(*) begin
        if(rd_addr_EX == rs1_addr_ID)begin
            if(wb_type_EX == WB_MEM)begin
                rs2_stall = 1;
                hazard_rs2 = 1;
                rs2_data = 32'b0;
            end
            else begin
                rs2_stall = 0;
                hazard_rs2 = 1;
                case (wb_type_EX)
                    WB_ALU: rs2_data = ALU_OUT_EX;
                    WB_IMM: rs2_data = imm_EX;
                    WB_PC4: rs2_data = pc_4_EX;
                    default: rs2_data = 32'b0;
                endcase
            end
        end

        else if(rd_addr_MEM == rs1_addr_ID)begin
            rs2_stall = 0;
            hazard_rs2 = 1;
            rs2_data = wr_data_WB_comb;
        end

        else begin
            hazard_rs2 = 0;
            rs2_stall = 0;
            rs2_data = 32'b0;
        end        
    end

    assign stall = rs1_stall | rs2_stall;

endmodule
