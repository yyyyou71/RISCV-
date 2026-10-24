module GPR_matrix(
    input clk,
    input rst_n,

    input wr_en,
    input [4:0]wr_addr,
    input [31:0]wr_data,

    input [4:0]rd_addr1,
    input [4:0]rd_addr2,
    output [31:0]rd_data1,
    output [31:0]rd_data2
);

    // 5-32 译码器
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] we;
    /* verilator lint_on UNUSEDSIGNAL */
    assign we = wr_en ? (32'b1 << wr_addr) : 32'b0;

    wire [31:0] dout [0:31];

    // x0 不实例化寄存器
    assign dout[0] = 32'b0;

    genvar i;
    generate
        for (i = 1; i < 32; i = i + 1) begin : g_reg
            Reg #(.WIDTH(32), .RESET_VAL(0)) u_Reg (
                .clk    (clk),
                .rst_n  (rst_n),
                .din    (wr_data),
                .dout   (dout[i]),
                .wen    (we[i])
            );
        end
    endgenerate

    assign rd_data1 = dout[rd_addr1];
    assign rd_data2 = dout[rd_addr2];

endmodule
