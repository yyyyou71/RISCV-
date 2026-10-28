`timescale 1ns/1ps
module TB_acore_ram_ip;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 0, rst = 1, we = 0;
    reg [13:0] addr = 0;
    reg [31:0] data = 0;
    reg [3:0] mask = 0;
    wire [31:0] q;
    reg [31:0] image [0:16383];
    reg [31:0] expected;
    integer i, j;
    always #20 clk = ~clk;
    memory_core #(.DUAL_IMAGE(1)) dut (
        .a_clk(clk), .a_rst(rst), .a_addr(addr), .a_wr_data(data),
        .a_wr_en(we), .a_wr_byte_en(mask), .a_rd_data(q));
    initial begin
        $readmemh("firmware/acore_dual_ram.hex", image);
        repeat (3) @(negedge clk);
        rst = 0;
        for (i = 0; i < 16384; i = i + 1) begin
            addr = i;
            @(negedge clk);
            if (q !== image[i]) $fatal(1, "Data RAM initial image mismatch at %0d", i);
        end
        addr = 16383;
        for (i = 0; i < 16; i = i + 1) begin
            we = 1; mask = 15; data = 32'h76543210;
            @(negedge clk);
            mask = i; data = 32'hfedcba98; expected = 32'h76543210;
            for (j = 0; j < 4; j = j + 1) if (mask[j]) expected[j*8 +: 8] = data[j*8 +: 8];
            @(negedge clk);
            if (q !== expected) $fatal(1, "Transparent write mismatch mask %h", mask);
            we = 0;
            @(negedge clk);
            if (q !== expected) $fatal(1, "Byte mask persistence mismatch %h", mask);
        end
        rst = 1; we = 1; data = 32'hbadbad00; mask = 15;
        @(negedge clk);
        if (q !== 0) $fatal(1, "Data RAM reset output failed");
        rst = 0; we = 0;
        @(negedge clk);
        if (q !== expected) $fatal(1, "Reset incorrectly changed RAM contents");
        $display("PASS Acore data RAM IP: 16384 initial words, 16 byte masks, transparent write, reset");
        $finish;
    end
endmodule
