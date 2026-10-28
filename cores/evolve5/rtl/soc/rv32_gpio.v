`timescale 1ns/1ps
module rv32_gpio #(
    parameter integer WIDTH = 8
) (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire ready,
    output reg [31:0] rdata,
    output reg error,
    input wire [WIDTH-1:0] pins_in,
    output reg [WIDTH-1:0] pins_out, pins_oe
);
    reg [WIDTH-1:0] input_meta /* synthesis syn_preserve=1 */;
    reg [WIDTH-1:0] input_sync /* synthesis syn_preserve=1 */;
    wire [31:0] byte_mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    wire [31:0] masked = wdata & byte_mask;
    assign ready = valid;
    always @* begin
        error = 0; rdata = 0;
        case (addr[11:2])
            10'h000: rdata = {{(32-WIDTH){1'b0}},pins_out};
            10'h001: rdata = {{(32-WIDTH){1'b0}},pins_oe};
            10'h002: begin rdata = {{(32-WIDTH){1'b0}},input_sync}; error = write; end
            10'h003,10'h004,10'h005: error = !write;
            default: error = 1;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            pins_out <= 0; pins_oe <= 0; input_meta <= 0; input_sync <= 0;
        end else begin
            input_meta <= pins_in; input_sync <= input_meta;
            if (valid && ready && write && !error) begin
                case (addr[11:2])
                    10'h000: pins_out <= (pins_out & ~byte_mask[WIDTH-1:0]) | masked[WIDTH-1:0];
                    10'h001: pins_oe <= (pins_oe & ~byte_mask[WIDTH-1:0]) | masked[WIDTH-1:0];
                    10'h003: pins_out <= pins_out | masked[WIDTH-1:0];
                    10'h004: pins_out <= pins_out & ~masked[WIDTH-1:0];
                    10'h005: pins_out <= pins_out ^ masked[WIDTH-1:0];
                endcase
            end
        end
    end
endmodule
