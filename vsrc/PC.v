module PC (
    input clk,
    input rst_n,
    input load_pc_en,
    input [31:0]load_pc,

    input stall,
    input flush,
    
    output valid_out,       
    output [31:0]pc
);
    reg [31:0]PC_counter;

    always @(posedge clk) begin
        if(!rst_n)
            PC_counter <= 32'b0;
        else begin
            if(stall)
                PC_counter <= PC_counter;
            else begin
                if(load_pc_en)
                    PC_counter <= load_pc;
                else
                    PC_counter <= PC_counter + 32'h4; 
            end 
        end
    end

    // valid 与 PC 同拍（组合）：复位 或 冲刷时为 0，其余为 1。
    //   它描述的是"本拍发出的取指是否有意义"，由 ROM 采样成 IF/ID 的 valid。
    //   绝不能用寄存器——寄存会滞后一拍，复位释放那一拍的取指会被当成无效丢掉
    //   （症状：程序从地址 4 开始跑，地址 0 的指令消失）。
    assign valid_out = rst_n & ~flush;

    assign pc   = PC_counter;

endmodule
