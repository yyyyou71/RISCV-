// 应用寄存器组。所有应用侧端口均工作在 clk 时钟域，内部不做跨时钟域（CDC）处理。
module rk_iic_regs (
    input wire clk,
    input wire rst_n,
    input wire [7:0] reg_addr,
    input wire [7:0] reg_wdata,
    input wire reg_write,
    output reg [7:0] reg_rdata,
    output reg [31:0] param_data,
    output reg param_update,
    input wire [7:0] uplink_data,
    input wire uplink_valid,
    output wire uplink_ready
);
    reg [7:0] scratch;
    reg [7:0] control;
    reg [31:0] param_shadow;
    reg [7:0] commit_seq;
    reg [7:0] mailbox_data;
    reg mailbox_valid;

    // 生产者必须在采样到 ready 为高之前，始终保持 valid 与 data 稳定不变。
    assign uplink_ready = rst_n && !mailbox_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            scratch <= 0;
            control <= 0;
            param_shadow <= 0;
            param_data <= 0;
            param_update <= 0;
            commit_seq <= 0;
            mailbox_data <= 0;
            mailbox_valid <= 0;
        end else begin
            param_update <= 0;
            if (uplink_valid && uplink_ready) begin
                mailbox_data <= uplink_data;
                mailbox_valid <= 1;
            end
            if (reg_write) begin
                case (reg_addr)
                    8'h00: scratch <= reg_wdata;
                    8'h01: control <= reg_wdata;
                    8'h10: param_shadow[7:0] <= reg_wdata;
                    8'h11: param_shadow[15:8] <= reg_wdata;
                    8'h12: param_shadow[23:16] <= reg_wdata;
                    8'h13: param_shadow[31:24] <= reg_wdata;
                    // 采用显式提交，避免多字节参数只写进去一部分就被生效。
                    8'h14: if (reg_wdata == 8'h01) begin
                        param_data <= param_shadow;
                        param_update <= 1;
                        commit_seq <= commit_seq + 1'b1;
                    end
                    // 读取不影响数据本身；由 RK 侧显式写确认，表示该字节已被取走。
                    8'h22: if (reg_wdata == 8'h01 && mailbox_valid)
                        mailbox_valid <= 0;
                    default: begin end
                endcase
            end
        end
    end

    // 串行引擎要求读数据来自寄存器输出（即打一拍），这一点与原始示例保持一致。
    always @(posedge clk) begin
        if (!rst_n) reg_rdata <= 0;
        else case (reg_addr)
            8'h00: reg_rdata <= scratch;
            8'h01: reg_rdata <= control;
            8'h02: reg_rdata <= {7'b0, mailbox_valid};
            8'h03: reg_rdata <= 8'h01; // 接口版本号
            8'h10: reg_rdata <= param_shadow[7:0];
            8'h11: reg_rdata <= param_shadow[15:8];
            8'h12: reg_rdata <= param_shadow[23:16];
            8'h13: reg_rdata <= param_shadow[31:24];
            8'h15: reg_rdata <= commit_seq;
            8'h20: reg_rdata <= {7'b0, mailbox_valid}; // 上行字节计数：0 或 1
            8'h21: reg_rdata <= mailbox_valid ? mailbox_data : 8'h00;
            default: reg_rdata <= 0;
        endcase
    end
endmodule
