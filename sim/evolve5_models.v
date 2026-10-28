module pango_evolve_rom (
    input wire clk, rst, addr_strobe,
    input wire [12:0] addr,
    output reg [31:0] rd_data
);
    reg [31:0] storage [0:8191];
    initial $readmemh("firmware/evolve5_rom.hex", storage);
    always @(posedge clk) begin
        if (rst) rd_data <= 0;
        else if (!addr_strobe) rd_data <= storage[addr];
    end
endmodule

module pango_evolve_ram (
    input wire a_clk, a_rst, a_wr_en,
    input wire [12:0] a_addr,
    input wire [3:0] a_wr_byte_en,
    input wire [31:0] a_wr_data,
    output reg [31:0] a_rd_data,
    input wire b_clk, b_rst, b_wr_en,
    input wire [12:0] b_addr,
    input wire [3:0] b_wr_byte_en,
    input wire [31:0] b_wr_data,
    output wire [31:0] b_rd_data
);
    reg [31:0] storage [0:8191];
    reg [31:0] next_word;
    integer byte_index;
    assign b_rd_data = 0;
    initial $readmemh("firmware/evolve5_ram.hex", storage);
    always @(posedge a_clk) begin
        if (a_rst) a_rd_data <= 0;
        else begin
            next_word = storage[a_addr];
            if (a_wr_en) begin
                for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                    if (a_wr_byte_en[byte_index])
                        next_word[byte_index*8 +: 8] = a_wr_data[byte_index*8 +: 8];
                storage[a_addr] <= next_word;
            end
            a_rd_data <= next_word;
        end
    end
endmodule

module pango_evolve_mul (
    input wire clk, rst, ce,
    input wire [31:0] a, b,
    output wire [63:0] p
);
    assign p = a * b;
endmodule
