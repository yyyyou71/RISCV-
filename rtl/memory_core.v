module memory_core #(
    parameter INIT_FILE = ""
) (
    input wire [13:0] a_addr,
    input wire [31:0] a_wr_data,
    input wire a_wr_en,
    input wire [3:0] a_wr_byte_en,
    input wire a_clk,
    input wire a_rst,
    output wire [31:0] a_rd_data
);
    pango_ram u_ip (
        .a_addr(a_addr),
        .a_wr_data(a_wr_data),
        .a_rd_data(a_rd_data),
        .a_wr_en(a_wr_en && !a_rst),
        .a_rst(a_rst),
        .a_wr_byte_en(a_wr_byte_en),
        .a_clk(a_clk),
        .b_addr(14'b0),
        .b_wr_data(32'b0),
        .b_rd_data(),
        .b_wr_en(1'b0),
        .b_rst(a_rst),
        .b_wr_byte_en(4'b0),
        .b_clk(a_clk)
    );
endmodule
