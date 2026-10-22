// EX 级一次处理一条乘法。start 使 IP 采样已经过前递的操作数；
// 经过 PIPE_STAGES 个使能上升沿后 ready 有效。处理器在下一个上升沿
// 接收结果，并让一直保持在 ID/EX 中的乘法指令继续前进。
module multiply_unit #(
    parameter integer PIPE_STAGES = 3
)(
    input clk,
    input rst_n,
    input start,
    input [1:0] operation, // funct3[1:0] 依次对应 MUL、MULH、MULHSU、MULHU
    input [31:0] rs1,
    input [31:0] rs2,
    output reg busy,
    output ready,
    output [31:0] result
);
    localparam integer COUNT_WIDTH = (PIPE_STAGES > 1) ? $clog2(PIPE_STAGES) : 1;
    localparam integer INITIAL_COUNT = PIPE_STAGES-1;
    reg [COUNT_WIDTH-1:0] remaining;
    reg low_half;

    // 使用一个固定为有符号模式的 IP：有符号操作数扩展符号位，
    // 无符号操作数补 0，以 33 位统一表示。乘积低 32 位与符号解释无关，
    // 所以 MUL 的两路输入都可以补 0，不需要额外的符号修正加减器。
    wire signed [32:0] a = {(operation == 2'b01 || operation == 2'b10) & rs1[31], rs1};
    wire signed [32:0] b = {(operation == 2'b01) & rs2[31], rs2};
    wire signed [65:0] p;
    wire ce = (start && !busy) || busy;

`ifdef PANGO_MULTIPLIER_IP
    // 按 README 中的配置，在 PDS 中生成同名的真实 IP。
    pango_multiplier_ip u_ip (
`else
    multiplier_core #(.PIPE_STAGES(PIPE_STAGES)) u_ip (
`endif
        .a(a), .b(b), .clk(clk), .rst(!rst_n), .ce(ce), .p(p)
    );

    assign ready = busy && (remaining == 0);
    assign result = low_half ? p[31:0] : p[63:32];

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0;
            remaining <= 0;
            low_half <= 0;
        end else if (busy) begin
            if (remaining != 0)
                remaining <= remaining - 1'b1;
            else
                busy <= 0;
        end else if (start) begin
            busy <= 1;
            remaining <= INITIAL_COUNT[COUNT_WIDTH-1:0];
            low_half <= (operation == 2'b00);
        end
    end
endmodule
