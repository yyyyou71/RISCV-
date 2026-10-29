`timescale 1ns/1ps
module TB_acore_fetch_ip;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 0, rst = 1, enable = 0;
    reg [12:0] a = 0, b = 0;
    wire [31:0] qa, qb;
    reg [31:0] expected [0:8191];
    reg [31:0] held_a, held_b;
    integer i;
    always #20 clk = ~clk;
    acore_fetch_memory dut (.clk(clk), .rst(rst), .enable(enable),
        .addr_a(a), .addr_b(b), .data_a(qa), .data_b(qb));
    initial begin
        $readmemh("firmware/acore_dual_rom.hex", expected);
        repeat (3) @(negedge clk);
        rst = 0;
        enable = 1;
        for (i = 0; i < 8192; i = i + 1) begin
            a = i;
            b = (i + 1) % 8192;
            @(negedge clk);
            if (qa !== expected[a] || qb !== expected[b])
                $fatal(1, "Dual fetch ROM mismatch at %0d", i);
        end
        held_a = qa; held_b = qb;
        enable = 0; a = 37; b = 219;
        repeat (4) @(negedge clk);
        if (qa !== held_a || qb !== held_b) $fatal(1, "Clock enable did not hold outputs");
        rst = 1; enable = 1;
        @(negedge clk);
        if (qa !== 0 || qb !== 0) $fatal(1, "Synchronous reset failed");
        $display("PASS dual-port fetch IP: 8192 address pairs, odd PC, wrap, enable, reset");
        $finish;
    end
endmodule
