`timescale 1ns/1ps

module TB_mem();

    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 16;

    reg                    clk;
    reg                    rst_n;
    reg  [1:0]             MemSize;      // 00=字节 01=半字 10=字
    reg                    MemUnsigned;  // 1=零扩展(LBU/LHU) 0=符号扩展(LB/LH)
    reg                    wr_en;
    reg  [ADDR_WIDTH-1:0]  wr_addr;
    reg  [31:0]            wr_data;
    reg                    rd_en;
    reg  [ADDR_WIDTH-1:0]  rd_addr;
    wire [31:0]            rd_data;

    //---------------- 时钟 ----------------
    initial clk = 0;
    always #10 clk = ~clk;    // 周期 20ns

    //---------------- DUT ----------------
    memory #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_memory (
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .MemSize     (MemSize     ),
        .MemUnsigned (MemUnsigned ),
        .wr_en       (wr_en       ),
        .wr_addr     (wr_addr     ),
        .wr_data     (wr_data     ),
        .rd_en       (rd_en       ),
        .rd_addr     (rd_addr     ),
        .rd_data     (rd_data     )
    );

    //========================================================
    // 复位
    //========================================================
    task do_reset;
        begin
            rst_n       = 1'b0;
            wr_en       = 1'b0;
            rd_en       = 1'b0;
            MemSize     = 2'b10;
            MemUnsigned = 1'b0;
            wr_addr     = {ADDR_WIDTH{1'b0}};
            rd_addr     = {ADDR_WIDTH{1'b0}};
            wr_data     = 32'h0;

            repeat(3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat(2) @(posedge clk);
        end
    endtask

    //========================================================
    // 写内存
    //========================================================
    task mem_write(
        input [1:0]            size,
        input [ADDR_WIDTH-1:0] addr,
        input [31:0]           data
    );
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            rd_en   = 1'b0;
            MemSize = size;
            wr_addr = addr;
            wr_data = data;

            @(posedge clk);        // 内存采样并写入
            @(negedge clk);        // 等写入完成

            wr_en   = 1'b0;
            wr_addr = {ADDR_WIDTH{1'b0}};
            wr_data = 32'h0;
        end
    endtask

    //========================================================
    // 读内存
    //========================================================
    task mem_read(
        input  [1:0]            size,
        input                   unsigned_en,
        input  [ADDR_WIDTH-1:0] addr,
        output [31:0]           data
    );
        begin
            @(negedge clk);
            rd_en       = 1'b1;
            wr_en       = 1'b0;
            MemSize     = size;
            MemUnsigned = unsigned_en;
            rd_addr     = addr;

            @(posedge clk);        // 内存采样地址
            @(negedge clk);        // 同步读：数据已稳定
            data = rd_data;

            rd_en   = 1'b0;
            rd_addr = {ADDR_WIDTH{1'b0}};
        end
    endtask

    //========================================================
    // 写后读校验：先写 data，再读回，比较是否等于 exp_data
    //========================================================
    task write_read_check(
        input [1:0]            size,
        input                  unsigned_en,
        input [ADDR_WIDTH-1:0] addr,
        input [31:0]           data,
        input [31:0]           exp_data,
        input [127:0]          name
    );
        reg [31:0] got;
        begin
            mem_write(size, addr, data);
            mem_read (size, unsigned_en, addr, got);
            if (got !== exp_data)
                $fatal(1, "[%0t] FAIL %0s @0x%04h: got %h, expect %h",
                         $time, name, addr, got, exp_data);
            else
                $display("[%0t] PASS %0s @0x%04h: %h",
                         $time, name, addr, got);
        end
    endtask

    //========================================================
    // 只读校验：不写，直接读，比较是否等于 exp_data
    //========================================================
    task read_check(
        input [1:0]            size,
        input                  unsigned_en,
        input [ADDR_WIDTH-1:0] addr,
        input [31:0]           exp_data,
        input [127:0]          name
    );
        reg [31:0] got;
        begin
            mem_read(size, unsigned_en, addr, got);
            if (got !== exp_data)
                $fatal(1, "[%0t] FAIL %0s @0x%04h: got %h, expect %h",
                         $time, name, addr, got, exp_data);
            else
                $display("[%0t] PASS %0s @0x%04h: %h",
                         $time, name, addr, got);
        end
    endtask

    //========================================================
    // 连续周期自检：检查上升沿前输出保持、上升沿后立即得到当拍读结果。
    task cycle_check;
        input we;
        input re;
        input [1:0] size;
        input unsigned_en;
        input [15:0] wa;
        input [15:0] ra;
        input [31:0] data;
        input [31:0] expected;
        reg [31:0] previous;
        begin
            @(negedge clk);
            previous = rd_data;
            wr_en = we;
            rd_en = re;
            MemSize = size;
            MemUnsigned = unsigned_en;
            wr_addr = wa;
            rd_addr = ra;
            wr_data = data;
            #1;
            if(rd_data !== previous)
                $fatal(1, "Read output changed before rising edge");
            @(posedge clk);
            #1;
            if(rd_data !== expected)
                $fatal(1, "Cycle read: got %h, expected %h", rd_data, expected);
        end
    endtask

    // 主测试流程
    //========================================================
    reg [31:0] rdata;
    integer    i;
    reg [15:0] addr_w;        // 辅助变量，承接 i*4 的位宽

    initial begin
        $dumpfile("TB_mem.vcd");
        $dumpvars(0, TB_mem);

        do_reset();

        //--------------------------------------------------
        // 1. 字读写：写后读，用 write_read_check
        //--------------------------------------------------
        $display("---- Test 1: word read/write ----");
        write_read_check(2'b10, 1'b0, 16'h0000, 32'hDEADBEEF, 32'hDEADBEEF, "SW/LW");
        write_read_check(2'b10, 1'b0, 16'h0004, 32'h00000000, 32'h00000000, "SW/LW zero");
        write_read_check(2'b10, 1'b0, 16'h0008, 32'hFFFFFFFF, 32'hFFFFFFFF, "SW/LW all-ones");

        //--------------------------------------------------
        // 2. 小端验证：写一个字，逐字节读
        //    0x11223344 -> mem[0x10]=44, 0x11=33, 0x12=22, 0x13=11
        //    用 read_check，不能再写 0 覆盖
        //--------------------------------------------------
        $display("---- Test 2: little-endian byte read ----");
        mem_write(2'b10, 16'h0010, 32'h11223344);
        read_check(2'b00, 1'b1, 16'h0010, 32'h00000044, "byte0=44");
        read_check(2'b00, 1'b1, 16'h0011, 32'h00000033, "byte1=33");
        read_check(2'b00, 1'b1, 16'h0012, 32'h00000022, "byte2=22");
        read_check(2'b00, 1'b1, 16'h0013, 32'h00000011, "byte3=11");

        //--------------------------------------------------
        // 3. 字节符号扩展 vs 零扩展
        //--------------------------------------------------
        $display("---- Test 3: byte sign/zero extension ----");
        mem_write(2'b00, 16'h0020, 32'h00000080);   // 写入 0x80
        read_check(2'b00, 1'b1, 16'h0020, 32'h00000080, "LBU 0x80");
        read_check(2'b00, 1'b0, 16'h0020, 32'hFFFFFF80, "LB  0x80");

        mem_write(2'b00, 16'h0021, 32'h0000007F);   // 写入 0x7F
        read_check(2'b00, 1'b1, 16'h0021, 32'h0000007F, "LBU 0x7F");
        read_check(2'b00, 1'b0, 16'h0021, 32'h0000007F, "LB  0x7F");

        //--------------------------------------------------
        // 4. 半字符号扩展 vs 零扩展
        //--------------------------------------------------
        $display("---- Test 4: halfword sign/zero extension ----");
        mem_write(2'b01, 16'h0030, 32'h00008000);   // 写入 0x8000
        read_check(2'b01, 1'b1, 16'h0030, 32'h00008000, "LHU 0x8000");
        read_check(2'b01, 1'b0, 16'h0030, 32'hFFFF8000, "LH  0x8000");

        mem_write(2'b01, 16'h0032, 32'h00007FFF);   // 写入 0x7FFF
        read_check(2'b01, 1'b1, 16'h0032, 32'h00007FFF, "LHU 0x7FFF");
        read_check(2'b01, 1'b0, 16'h0032, 32'h00007FFF, "LH  0x7FFF");

        //--------------------------------------------------
        // 5. 字节写、字读：验证低字节写不影响其他字节
        //    先写 0xAABBCCDD，再改字节 0x0040 为 0x11
        //    读回应为 0xAABBCC11
        //--------------------------------------------------
        $display("---- Test 5: byte write into word ----");
        mem_write(2'b10, 16'h0040, 32'hAABBCCDD);
        mem_write(2'b00, 16'h0040, 32'h00000011);
        read_check(2'b10, 1'b0, 16'h0040, 32'hAABBCC11, "word=AA BB CC 11");

        //--------------------------------------------------
        // 6. 半字写、字读
        //    先写 0x55667788，再改半字 0x0050 为 0x1234
        //    读回应为 0x55661234
        //--------------------------------------------------
        $display("---- Test 6: halfword write into word ----");
        mem_write(2'b10, 16'h0050, 32'h55667788);
        mem_write(2'b01, 16'h0050, 32'h00001234);
        read_check(2'b10, 1'b0, 16'h0050, 32'h55661234, "word=55 66 12 34");

        //--------------------------------------------------
        // 7. 高半字写
        //--------------------------------------------------
        $display("---- Test 7: upper halfword write ----");
        mem_write(2'b10, 16'h0060, 32'h55667788);
        mem_write(2'b01, 16'h0062, 32'h0000ABCD);
        read_check(2'b10, 1'b0, 16'h0060, 32'hABCD7788, "word=AB CD 77 88");

        //--------------------------------------------------
        // 8. 批量写、批量读
        //--------------------------------------------------
        // verilator lint_off WIDTH
        $display("---- Test 8: bulk write/read ----");
        for (i = 0; i < 16; i = i + 1) begin
            addr_w = i * 4;                          // 先赋给 16 位变量
            mem_write(2'b10, addr_w, 32'hA0000000 + i);
        end
        for (i = 0; i < 16; i = i + 1) begin
            addr_w = i * 4;
            mem_read(2'b10, 1'b0, addr_w, rdata);
            if (rdata !== (32'hA0000000 + i))
                $fatal(1, "[%0t] FAIL bulk[%0d]: got %h, expect %h",
                         $time, i, rdata, 32'hA0000000 + i);
            else
                $display("[%0t] PASS bulk[%0d] = %h", $time, i, rdata);
        end
        // verilator lint_on WIDTH
        //--------------------------------------------------
        // 9. 连续读同一地址（验证没有副作用）
        //--------------------------------------------------
        $display("---- Test 9: repeated read ----");
        mem_write(2'b10, 16'h0080, 32'hCAFEBABE);
        mem_read (2'b10, 1'b0, 16'h0080, rdata);
        $display("[%0t] read1 = %h", $time, rdata);
        mem_read (2'b10, 1'b0, 16'h0080, rdata);
        $display("[%0t] read2 = %h", $time, rdata);
        mem_read (2'b10, 1'b0, 16'h0080, rdata);
        $display("[%0t] read3 = %h", $time, rdata);

        //--------------------------------------------------
        // 10. 读写交替
        //     前两个是写后读，用 write_read_check
        //     后两个是只读，用 read_check
        //--------------------------------------------------
        $display("---- Test 10: write/read alternation ----");
        write_read_check(2'b10, 1'b0, 16'h0090, 32'h12345678, 32'h12345678, "alt-wr1");
        write_read_check(2'b10, 1'b0, 16'h0094, 32'h9ABCDEF0, 32'h9ABCDEF0, "alt-wr2");
        read_check(2'b10, 1'b0, 16'h0090, 32'h12345678, "alt-rd1");
        read_check(2'b10, 1'b0, 16'h0094, 32'h9ABCDEF0, "alt-rd2");

        //--------------------------------------------------
        // 结束
        //--------------------------------------------------
        $display("---- Test 11: back-to-back reads and output hold ----");
        mem_write(2'b10, 16'h0100, 32'h807FFF01);
        mem_write(2'b10, 16'h0104, 32'h8000AABB);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0100, 0, 32'h807FFF01);
        cycle_check(0, 1, 2'b00, 0, 0, 16'h0103, 0, 32'hFFFFFF80);
        cycle_check(0, 1, 2'b00, 1, 0, 16'h0103, 0, 32'h00000080);
        cycle_check(0, 1, 2'b01, 0, 0, 16'h0102, 0, 32'hFFFF807F);
        cycle_check(0, 1, 2'b01, 1, 0, 16'h0102, 0, 32'h0000807F);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0104, 0, 32'h8000AABB);
        cycle_check(0, 0, 2'b00, 1, 0, 16'h0100, 0, 32'h8000AABB);
        cycle_check(1, 0, 2'b00, 0, 16'h0100, 0, 32'h55, 32'h8000AABB);
        cycle_check(0, 0, 2'b10, 0, 0, 0, 0, 32'h8000AABB);

        $display("---- Test 12: simultaneous read/write and persistence ----");
        cycle_check(1, 1, 2'b00, 0, 16'h0101, 16'h0101, 32'hEE, 32'hFFFFFFEE);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0100, 0, 32'h807FEE55);
        cycle_check(1, 1, 2'b01, 1, 16'h0102, 16'h0102, 32'h1234, 32'h00001234);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0100, 0, 32'h1234EE55);
        cycle_check(1, 1, 2'b10, 0, 16'h0100, 16'h0100, 32'hDEADBEEF, 32'hDEADBEEF);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0100, 0, 32'hDEADBEEF);
        // 同一个字内允许写、读选择不同字节。
        cycle_check(1, 1, 2'b00, 1, 16'h0100, 16'h0103, 32'h11, 32'h000000DE);
        cycle_check(0, 1, 2'b10, 0, 0, 16'h0100, 0, 32'hDEADBE11);
        cycle_check(0, 0, 2'b10, 0, 0, 0, 0, 32'hDEADBE11);

        repeat(5) @(posedge clk);
        $display("---- All tests done ----");
        $finish;
    end

endmodule
