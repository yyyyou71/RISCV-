module ROM(
    /* verilator lint_off UNUSEDSIGNAL */
    input clk,
    input rst_n,

    input flush,
    input stall,
    
    input [31:0]pc_in,

    input valid_in,

    output reg [31:0]pc_out,
    output [31:0]pc_4_out,
    output reg valid_out,
    output reg [31:0]instruction
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

    always @(posedge clk) begin
        if(!rst_n | flush | !valid_in)
            instruction <= 32'h00000013;
        else begin
            if(stall)
                instruction <= instruction;
            else
                instruction <= rom[(pc_in>>2)];
        end
    end

    always @(posedge clk) begin
        if(!rst_n | flush | !valid_in)
            valid_out <= 0;
        else begin
            if(stall)
                valid_out <= valid_out;
            else
                valid_out <= valid_in;
        end
    end

    always @(posedge clk) begin
        if(!rst_n)
            pc_out <= 0;
        else begin
            if(stall)
                pc_out <= pc_out;
            else
                pc_out <= pc_in;
        end
    end
    assign pc_4_out = pc_out + 32'h4;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
