module ROM_core (
    input wire clk,
    input wire [12:0] addr,
    input wire rst,
    input wire addr_strobe,
    output wire [31:0] rd_data
);
    pango_rom u_ip (
        .addr(addr),
        .rd_data(rd_data),
        .clk(clk),
        .addr_strobe(addr_strobe),
        .rst(rst)
    );
endmodule
