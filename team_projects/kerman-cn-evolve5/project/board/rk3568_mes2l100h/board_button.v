`timescale 1ns/1ps
module board_button #(
    parameter integer DEBOUNCE_CYCLES = 250000
) (
    input wire clk, reset, key_n,
    output wire pressed
);
    reg [1:0] key_sync /* synthesis syn_preserve=1 */;
    reg stable_n;
    reg [31:0] change_count;
    always @(posedge clk) begin
        if (reset) begin
            key_sync <= 2'b11; stable_n <= 1; change_count <= 0;
        end else begin
            key_sync <= {key_sync[0],key_n};
            if (key_sync[1] == stable_n) change_count <= 0;
            else if (change_count >= DEBOUNCE_CYCLES-1) begin
                stable_n <= key_sync[1]; change_count <= 0;
            end else change_count <= change_count + 1;
        end
    end
    assign pressed = !stable_n;
endmodule
