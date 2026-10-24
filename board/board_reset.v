module board_reset #(
    parameter integer HOLD_CYCLES = 250000
) (
    input wire clk,
    input wire key0_n,
    output wire rst_n
);
    reg [1:0] release_sync = 2'b00 /* synthesis syn_preserve=1 */;
    reg [31:0] release_count = 32'b0;
    reg hold_reset = 1'b1;

    always @(posedge clk or negedge key0_n) begin
        if (!key0_n)
            release_sync <= 2'b00;
        else
            release_sync <= {release_sync[0], 1'b1};
    end

    always @(posedge clk) begin
        if (!release_sync[1]) begin
            release_count <= 32'b0;
            hold_reset <= 1'b1;
        end
        else if (hold_reset) begin
            if (release_count >= HOLD_CYCLES - 1)
                hold_reset <= 1'b0;
            else
                release_count <= release_count + 32'd1;
        end
    end

    assign rst_n = release_sync[1] && !hold_reset;
endmodule
