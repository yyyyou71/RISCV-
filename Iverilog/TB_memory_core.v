`timescale 1ns/1ps

module TB_memory_core;
    reg a_clk = 1'b0;
    reg a_rst = 1'b0;
    reg [13:0] a_addr = 14'b0;
    reg [31:0] a_wr_data = 32'b0;
    reg a_wr_en = 1'b0;
    reg [3:0] a_wr_byte_en = 4'b0;
    wire [31:0] a_rd_data;

    integer checks = 0;
    integer mask;
    reg [31:0] expected;
    reg [31:0] expanded_mask;

    always #5 a_clk = ~a_clk;

    memory_core dut (
        .a_addr(a_addr),
        .a_wr_data(a_wr_data),
        .a_wr_en(a_wr_en),
        .a_wr_byte_en(a_wr_byte_en),
        .a_clk(a_clk),
        .a_rst(a_rst),
        .a_rd_data(a_rd_data)
    );

    // 在下降沿施加输入，并在上升沿非阻塞赋值完成后检查输出。
    task cycle_check;
        input rst;
        input [13:0] addr;
        input wr_en;
        input [3:0] byte_en;
        input [31:0] data;
        input [31:0] want;
        reg [31:0] previous;
        begin
            @(negedge a_clk);
            previous = a_rd_data;
            a_rst = rst;
            a_addr = addr;
            a_wr_en = wr_en;
            a_wr_byte_en = byte_en;
            a_wr_data = data;
            #1;
            if(a_rd_data !== previous)
                $fatal(1, "Output changed before rising edge: got %h, previous %h",
                       a_rd_data, previous);
            @(posedge a_clk);
            #1;
            if(a_rd_data !== want)
                $fatal(1, "addr=%h wr_en=%b byte_en=%b: got %h, expected %h",
                       addr, wr_en, byte_en, a_rd_data, want);
            checks = checks + 1;
        end
    endtask

    initial begin
        // 复位沿不写入；未初始化 RAM 的读取结果仍然为 X。
        cycle_check(1'b1, 14'h0000, 1'b1, 4'b1111, 32'hDEADBEEF, 32'b0);
        cycle_check(1'b0, 14'h0000, 1'b0, 4'b0000, 32'b0, 32'hxxxxxxxx);

        // 写当拍输出新值，紧接着的下一拍读回，确认数据确实存入 RAM。
        cycle_check(1'b0, 14'h0000, 1'b1, 4'b1111, 32'h11223344, 32'h11223344);
        cycle_check(1'b0, 14'h0000, 1'b0, 4'b0000, 32'b0, 32'h11223344);

        // 相邻字地址互不干扰；最高字地址映射到最后四个字节。
        cycle_check(1'b0, 14'h0001, 1'b1, 4'b1111, 32'h55667788, 32'h55667788);
        cycle_check(1'b0, 14'h3fff, 1'b1, 4'b1111, 32'hAABBCCDD, 32'hAABBCCDD);
        cycle_check(1'b0, 14'h0000, 1'b0, 4'b1111, 32'hFFFFFFFF, 32'h11223344);
        cycle_check(1'b0, 14'h0001, 1'b0, 4'b0000, 32'b0, 32'h55667788);
        cycle_check(1'b0, 14'h3fff, 1'b0, 4'b0000, 32'b0, 32'hAABBCCDD);
        cycle_check(1'b0, 14'h3fff, 1'b1, 4'b1000, 32'h12345678, 32'h12BBCCDD);
        cycle_check(1'b0, 14'h3fff, 1'b0, 4'b0000, 32'b0, 32'h12BBCCDD);

        // 穷举全部 16 种字节使能，分别检查写当拍和下一拍读回。
        for(mask = 0; mask < 16; mask = mask + 1) begin
            cycle_check(1'b0, 14'h0020, 1'b1, 4'b1111, 32'h11223344, 32'h11223344);
            expanded_mask = {{8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}};
            expected = (32'hAABBCCDD & expanded_mask) | (32'h11223344 & ~expanded_mask);
            cycle_check(1'b0, 14'h0020, 1'b1, mask[3:0], 32'hAABBCCDD, expected);
            cycle_check(1'b0, 14'h0020, 1'b0, 4'b0000, 32'b0, expected);
        end

        // 同一地址连续写入，未使能字节必须来自最近一次存储结果。
        cycle_check(1'b0, 14'h0030, 1'b1, 4'b1111, 32'h11223344, 32'h11223344);
        cycle_check(1'b0, 14'h0030, 1'b1, 4'b0001, 32'h000000AA, 32'h112233AA);
        cycle_check(1'b0, 14'h0030, 1'b1, 4'b0010, 32'h0000BB00, 32'h1122BBAA);
        cycle_check(1'b0, 14'h0030, 1'b1, 4'b1100, 32'hCCDD0000, 32'hCCDDBBAA);
        cycle_check(1'b0, 14'h0030, 1'b0, 4'b0000, 32'b0, 32'hCCDDBBAA);

        // 总写使能为零或字节使能全零都不能修改存储内容。
        cycle_check(1'b0, 14'h0030, 1'b0, 4'b1111, 32'hFFFFFFFF, 32'hCCDDBBAA);
        cycle_check(1'b0, 14'h0030, 1'b1, 4'b0000, 32'hFFFFFFFF, 32'hCCDDBBAA);
        cycle_check(1'b0, 14'h0030, 1'b0, 4'b0000, 32'b0, 32'hCCDDBBAA);

        // 同步复位清输出并禁止写入，解除后仍读到复位前的内容。
        cycle_check(1'b1, 14'h0030, 1'b1, 4'b1111, 32'hFFFFFFFF, 32'b0);
        cycle_check(1'b1, 14'h0000, 1'b0, 4'b0000, 32'b0, 32'b0);
        cycle_check(1'b0, 14'h0030, 1'b0, 4'b0000, 32'b0, 32'hCCDDBBAA);
        cycle_check(1'b0, 14'h0000, 1'b0, 4'b0000, 32'b0, 32'h11223344);

        $display("PASS: memory_core (%0d cycle checks)", checks);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "memory_core test timed out");
    end
endmodule
