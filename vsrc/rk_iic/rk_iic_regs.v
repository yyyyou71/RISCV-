// Application register bank. All application ports use clk; no CDC is provided.
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

    // Producer must keep valid/data stable until ready is sampled high.
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
                    // Explicit commit prevents partial multi-byte parameters.
                    8'h14: if (reg_wdata == 8'h01) begin
                        param_data <= param_shadow;
                        param_update <= 1;
                        commit_seq <= commit_seq + 1'b1;
                    end
                    // Read is non-destructive; RK explicitly acknowledges consumption.
                    8'h22: if (reg_wdata == 8'h01 && mailbox_valid)
                        mailbox_valid <= 0;
                    default: begin end
                endcase
            end
        end
    end

    // The serial engine expects registered read data, as in the source example.
    always @(posedge clk) begin
        if (!rst_n) reg_rdata <= 0;
        else case (reg_addr)
            8'h00: reg_rdata <= scratch;
            8'h01: reg_rdata <= control;
            8'h02: reg_rdata <= {7'b0, mailbox_valid};
            8'h03: reg_rdata <= 8'h01; // Interface version
            8'h10: reg_rdata <= param_shadow[7:0];
            8'h11: reg_rdata <= param_shadow[15:8];
            8'h12: reg_rdata <= param_shadow[23:16];
            8'h13: reg_rdata <= param_shadow[31:24];
            8'h15: reg_rdata <= commit_seq;
            8'h20: reg_rdata <= {7'b0, mailbox_valid}; // Count: 0 or 1
            8'h21: reg_rdata <= mailbox_valid ? mailbox_data : 8'h00;
            default: reg_rdata <= 0;
        endcase
    end
endmodule
