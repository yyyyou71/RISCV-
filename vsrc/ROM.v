`ifndef PROG_FILE
  `define PROG_FILE "program/sum_1_10_c.hex" // 宏定义
`endif

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
    output [31:0]instruction
);

    wire [31:0]addr1 = (pc_in>>2);
    wire [31:0]instruction_buffer1;

    reg flush_buffer;

    ROM_core u_ROM_core(
        .clk         (clk            ),
        .addr        (addr1[12:0]    ),
        .rst         (!rst_n         ),
        .addr_strobe (stall          ),
        .rd_data     (instruction_buffer1)
    );
    

    always @(posedge clk) begin
        flush_buffer <= !rst_n | flush | !valid_in;
    end

    assign instruction = flush_buffer ? 32'h00000013 : instruction_buffer1;
    

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
