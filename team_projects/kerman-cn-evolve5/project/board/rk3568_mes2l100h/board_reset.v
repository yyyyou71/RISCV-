`timescale 1ns/1ps
// Configuration-time initial values are intentional: verify FF INIT/GSR in PDS.
// KEY0 asserts reset asynchronously through a two-flop release synchronizer.
// Reset is held until the button has stayed released for HOLD_CYCLES clocks.
module board_reset #(
    parameter integer HOLD_CYCLES = 250000
) (
    input wire clk, key0_n, soft_reset,
    output wire reset
);
    reg [1:0] release_sync = 2'b00 /* synthesis syn_preserve=1 */;
    reg [31:0] release_count = 0;
    reg hold_reset = 1'b1;
    always @(posedge clk or negedge key0_n) begin
        if (!key0_n) release_sync <= 2'b00;
        else release_sync <= {release_sync[0],1'b1};
    end
    always @(posedge clk) begin
        if (!release_sync[1] || soft_reset) begin
            release_count <= 0;
            hold_reset <= 1;
        end else if (hold_reset) begin
            if (release_count >= HOLD_CYCLES-1) hold_reset <= 0;
            else release_count <= release_count + 1;
        end
    end
    assign reset = hold_reset || !release_sync[1];
endmodule
