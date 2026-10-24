`timescale 1ns/1ps

module TB_storage_images;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg stall = 1'b0;
    reg [13:0] address = 14'b0;
    wire [31:0] instruction;
    wire [31:0] data;
    reg [31:0] rom_image [0:8191];
    reg [31:0] ram_image [0:16383];
    reg [31:0] held_instruction;
    integer word_index;

    always #20 clk = ~clk;

    ROM_core rom (.clk(clk), .rst(rst), .addr(address[12:0]),
                  .addr_strobe(stall), .rd_data(instruction));
    memory_core ram (.a_clk(clk), .a_rst(rst), .a_addr(address),
                     .a_wr_en(1'b0), .a_wr_byte_en(4'b0),
                     .a_wr_data(32'b0), .a_rd_data(data));

    initial begin
        $readmemh("firmware/rom.hex", rom_image);
        $readmemh("firmware/ram.hex", ram_image);
        repeat (3) @(negedge clk);
        rst = 1'b0;
        for (word_index = 0; word_index < 16384; word_index = word_index + 1) begin
            @(negedge clk);
            address = word_index[13:0];
            @(posedge clk);
            #1;
            if (data !== ram_image[word_index])
                $fatal(1, "RAM image mismatch at word %0d: got %h expected %h",
                       word_index, data, ram_image[word_index]);
            if (word_index < 8192 && instruction !== rom_image[word_index])
                $fatal(1, "ROM image mismatch at word %0d", word_index);
        end
        held_instruction = instruction;
        for (word_index = 0; word_index < 4; word_index = word_index + 1) begin
            @(negedge clk);
            stall = 1'b1;
            address = word_index[13:0];
            @(posedge clk);
            #1;
            if (instruction !== held_instruction)
                $fatal(1, "ROM did not hold its address during a stall");
        end
        @(negedge clk);
        stall = 1'b0;
        address = 14'b0;
        @(posedge clk);
        #1;
        if (instruction !== rom_image[0])
            $fatal(1, "ROM did not resume after a stall");
        $display("PASS: all 8192 ROM words, 16384 RAM words and ROM address hold at 25 MHz");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Storage image test timed out");
    end
endmodule
