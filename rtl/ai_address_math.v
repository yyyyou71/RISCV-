`default_nettype none
// (((a*b + index_add) * pitch + inner) << element_shift) + base, modulo 2^32.
// A held request/result replaces the engine's chained address multiplications.
module ai_address_math(
    input wire clk,rst_n,clear,in_valid,
    output wire in_ready,out_valid,
    input wire out_ready,
    input wire [31:0] a,b,index_add,pitch,inner,base,
    input wire [1:0] element_shift,
    output reg [31:0] address
);
    localparam [3:0] IDLE=0,MUL1=1,WAIT1=2,INDEX=3,MUL2=4,WAIT2=5,INNER=6,SCALE=7,BASE=8,RESULT=9;
    reg [3:0] state;
    reg [31:0] a_reg,b_reg,add_reg,pitch_reg,inner_reg,base_reg,work,scaled;
    reg [1:0] shift_reg;
    wire result_valid;wire [63:0] product;
    ai_mul32_pipeline u_mul(.clk(clk),.rst_n(rst_n),.clear(clear),
        .in_valid(state==MUL1 || state==MUL2),.a(a_reg),.b(b_reg),.out_valid(result_valid),.product(product));
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;a_reg<=0;b_reg<=0;add_reg<=0;pitch_reg<=0;inner_reg<=0;base_reg<=0;
            work<=0;scaled<=0;shift_reg<=0;address<=0;
        end else if(clear)state<=IDLE;
        else case(state)
            IDLE:if(in_valid)begin
                a_reg<=a;b_reg<=b;add_reg<=index_add;pitch_reg<=pitch;inner_reg<=inner;
                base_reg<=base;shift_reg<=element_shift;state<=MUL1;
            end
            MUL1:state<=WAIT1;
            WAIT1:if(result_valid)begin work<=product[31:0];state<=INDEX;end
            INDEX:begin a_reg<=work+add_reg;b_reg<=pitch_reg;state<=MUL2;end
            MUL2:state<=WAIT2;
            WAIT2:if(result_valid)begin work<=product[31:0];state<=INNER;end
            INNER:begin scaled<=work+inner_reg;state<=SCALE;end
            SCALE:begin work<=scaled<<shift_reg;state<=BASE;end
            BASE:begin address<=base_reg+work;state<=RESULT;end
            RESULT:if(out_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
