module acore_fetch_memory (
    input clk, rst, enable,
    input [12:0] addr_a, addr_b,
    output reg [31:0] data_a, data_b
);
    reg [31:0] words [0:8191];
    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) words[i] = 32'h00000013;
        $readmemh(`PROG_FILE, words);
    end
    always @(posedge clk) begin
        if (rst) begin data_a <= 0; data_b <= 0; end
        else if (enable) begin data_a <= words[addr_a]; data_b <= words[addr_b]; end
    end
endmodule
