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
    localparam [3:0] IDLE=0,MUL1=1,WAIT1=2,INDEX=3,MUL2=4,WAIT2=5,INNER=6,SCALE=7,BASE=8,RESULT=9,PITCH_SHIFT=10;
    reg [3:0] state;
    // Keep the request snapshot in fabric registers. Otherwise ADS absorbs
    // these registers into DSP inputs and places the engine's operand select
    // (including co_base/weight_lane) on the full path to a distant APM.
    (* syn_preserve=1, syn_keep=1 *) reg [31:0] a_reg,b_reg;
    reg [31:0] add_reg,pitch_reg,inner_reg,base_reg,work,scaled;
    reg [1:0] shift_reg;
    // All addresses wrap modulo 2^32. Terms a_hi*b_hi and the high halves
    // of cross products cannot contribute: retain only the three low products.
    reg [31:0] p00;
    reg [15:0] p01,p10;
    reg [31:0] product;
    reg [1:0] mul_valid;
    wire result_valid=mul_valid[1];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin p00<=0;p01<=0;p10<=0;product<=0;mul_valid<=0;end
        else begin
            mul_valid<=clear ? 2'b0 : {mul_valid[0],state==MUL1 || state==MUL2};
            p00<=a_reg[15:0]*b_reg[15:0];
            p01<=a_reg[15:0]*b_reg[31:16];
            p10<=a_reg[31:16]*b_reg[15:0];
            product<={p00[31:16]+p01+p10,p00[15:0]};
        end
    end
    reg fast_pitch;
    reg [4:0] pitch_shift;
    // Channel pitches in the deployed network are powers of two. Keep the
    // general multiplier fallback for arbitrary legal descriptors.
    always @* begin
        fast_pitch=1;pitch_shift=0;
        case(pitch_reg)
            1:pitch_shift=0;2:pitch_shift=1;4:pitch_shift=2;8:pitch_shift=3;
            16:pitch_shift=4;32:pitch_shift=5;64:pitch_shift=6;128:pitch_shift=7;
            256:pitch_shift=8;512:pitch_shift=9;1024:pitch_shift=10;2048:pitch_shift=11;
            default:fast_pitch=0;
        endcase
    end
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
                base_reg<=base;shift_reg<=element_shift;
                if(b==1)begin work<=a;state<=INDEX;end else state<=MUL1;
            end
            MUL1:state<=WAIT1;
            WAIT1:if(result_valid)begin work<=product[31:0];state<=INDEX;end
            INDEX:begin a_reg<=work+add_reg;b_reg<=pitch_reg;state<=fast_pitch?PITCH_SHIFT:MUL2;end
            PITCH_SHIFT:begin work<=a_reg<<pitch_shift;state<=INNER;end
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
