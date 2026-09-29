module ROM(
    /* verilator lint_off UNUSEDSIGNAL */
    input [31:0]pc,
    output [31:0]instruction
);

    reg [31:0] rom [0:1023];

    // 初始化，从 hex 文件加载
    initial begin
        // 可以在这里给个默认值，防止文件没找到导致读出 X 态
        for (int i = 0; i < 1024; i = i + 1) begin
            rom[i] = 32'h00000013; // NOP 指令
        end
        $readmemh("program.hex", rom);
    end

    assign instruction = rom[(pc>>2)];

endmodule
/* verilator lint_on UNUSEDSIGNAL */
