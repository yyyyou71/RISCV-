`timescale 1ns/1ps
// Polling timer. pending is reserved for a future interrupt connection.
// Count writes require a stopped counter. No implicit CSR or CLINT semantics.
module rv32_timer (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire ready,
    output reg [31:0] rdata,
    output reg error,
    output wire pending
);
    reg [63:0] count, compare;
    reg enable, compare_enable;
    wire [31:0] mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    assign ready = valid;
    assign pending = compare_enable && count >= compare;
    always @* begin
        rdata = 0; error = 0;
        case (addr[11:2])
            10'h000: begin rdata = count[31:0]; error = write && enable; end
            10'h001: begin rdata = count[63:32]; error = write && enable; end
            10'h002: rdata = compare[31:0];
            10'h003: rdata = compare[63:32];
            10'h004: rdata = {30'b0,compare_enable,enable};
            10'h005: begin rdata = {31'b0,pending}; error = write; end
            default: error = 1;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            count <= 0; compare <= 64'hffffffffffffffff;
            enable <= 0; compare_enable <= 0;
        end else begin
            if (enable) count <= count + 1;
            if (valid && ready && write && !error) begin
                case (addr[11:2])
                    10'h000: count[31:0] <= (count[31:0] & ~mask) | (wdata & mask);
                    10'h001: count[63:32] <= (count[63:32] & ~mask) | (wdata & mask);
                    10'h002: compare[31:0] <= (compare[31:0] & ~mask) | (wdata & mask);
                    10'h003: compare[63:32] <= (compare[63:32] & ~mask) | (wdata & mask);
                    10'h004: if (wstrb[0]) begin
                        enable <= wdata[0]; compare_enable <= wdata[1];
                    end
                endcase
            end
        end
    end
endmodule
