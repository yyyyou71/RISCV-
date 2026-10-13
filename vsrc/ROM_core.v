`ifndef PROG_FILE
  `define PROG_FILE "program/sum_1_10_c.hex" // 宏定义
`endif

module ROM_core(
    /* verilator lint_off UNUSEDSIGNAL */
    input clk,
    input [12:0]addr,
    input rst,
    input addr_strobe,  // 输入1锁存输出
    output reg [31:0]rd_data
);
    reg [31:0] rom [0:8192];
    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin
            rom[i] = 32'h00000013; // NOP 指令
        end
        $readmemh(`PROG_FILE, rom);
    end

    always @(posedge clk) begin
        if(rst)begin
            rd_data <= 32'h00000013;  
        end

        else if(addr_strobe) begin
            rd_data <= rd_data;
        end

        else begin
            rd_data <= rom[addr];
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
