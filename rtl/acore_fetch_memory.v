module acore_fetch_memory (
    input clk, rst, enable,
    input [12:0] addr_a, addr_b,
    output [31:0] data_a, data_b
);
    pango_acore_fetch u_ip (
        .a_clk(clk), .a_rst(rst), .a_clk_en(enable), .a_wr_en(1'b0),
        .a_addr(addr_a), .a_wr_data(32'b0), .a_wr_byte_en(4'b0), .a_rd_data(data_a),
        .b_clk(clk), .b_rst(rst), .b_clk_en(enable), .b_wr_en(1'b0),
        .b_addr(addr_b), .b_wr_data(32'b0), .b_wr_byte_en(4'b0), .b_rd_data(data_b)
    );
endmodule
