module GPR_matrix #(
    parameter integer ENABLE_DUAL = 0
)(
    input clk,
    input rst_n,

    input wr_en,
    input [4:0]wr_addr,
    input [31:0]wr_data,

    input [4:0]rd_addr1,
    input [4:0]rd_addr2,
    output [31:0]rd_data1,
    output [31:0]rd_data2,
    input wr_en_b,
    input [4:0]wr_addr_b,
    input [31:0]wr_data_b,
    input [4:0]rd_addr3,
    input [4:0]rd_addr4,
    output [31:0]rd_data3,
    output [31:0]rd_data4
);

    // 5-32 译码器
    /* verilator lint_off UNUSED */
    wire [31:0] we;
    /* verilator lint_on UNUSED */
    assign we = wr_en ? (32'b1 << wr_addr) : 32'b0;
    wire [31:0] we_b = (ENABLE_DUAL != 0 && wr_en_b) ? (32'b1 << wr_addr_b) : 32'b0;

    wire [31:0] dout [0:31];

    // x0 不实例化寄存器
    assign dout[0] = 32'b0;

    genvar i;
    generate
        for (i = 1; i < 32; i = i + 1) begin : g_reg
            Reg #(.WIDTH(32), .RESET_VAL(0)) u_Reg (
                .clk    (clk),
                .rst_n  (rst_n),
                .din    (we_b[i] ? wr_data_b : wr_data),
                .dout   (dout[i]),
                .wen    (we[i] | we_b[i])
            );
        end
    endgenerate

    assign rd_data1 = dout[rd_addr1];
    assign rd_data2 = dout[rd_addr2];
    assign rd_data3 = (ENABLE_DUAL != 0) ? dout[rd_addr3] : 32'b0;
    assign rd_data4 = (ENABLE_DUAL != 0) ? dout[rd_addr4] : 32'b0;

endmodule
