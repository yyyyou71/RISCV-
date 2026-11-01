`default_nettype none
// Exact signed64 x unsigned31, eight registered 16x16 partial products.
module scale_mul64x31(
    input wire clk,rst_n,in_valid,
    output wire in_ready,
    input wire signed [63:0] value,
    input wire [30:0] multiplier,
    output wire out_valid,
    input wire out_ready,
    output reg signed [95:0] result
);
    localparam [2:0] IDLE=0,PART=1,ACCUM=2,SIGN=3,RESULT=4;
    reg [2:0] state,index;
    reg negative;
    reg [63:0] magnitude;
    reg [30:0] factor;
    reg [31:0] partial;
    reg [95:0] accumulator,term;
    wire [15:0] limb_a=magnitude[index[2:1]*16+:16];
    wire [15:0] limb_b=index[0]?{1'b0,factor[30:16]}:factor[15:0];
    always @*case({1'b0,index[2:1]}+{2'b0,index[0]})
        0:term={64'b0,partial};
        1:term={48'b0,partial,16'b0};
        2:term={32'b0,partial,32'b0};
        3:term={16'b0,partial,48'b0};
        default:term={partial,64'b0};
    endcase
    assign in_ready=rst_n && state==IDLE;
    assign out_valid=rst_n && state==RESULT;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin state<=IDLE;index<=0;negative<=0;magnitude<=0;factor<=0;partial<=0;accumulator<=0;result<=0;end
        else case(state)
            IDLE:if(in_valid)begin
                negative<=value[63];magnitude<=value[63]?-value:value;
                factor<=multiplier;index<=0;accumulator<=0;state<=PART;
            end
            PART:begin partial<=limb_a*limb_b;state<=ACCUM;end
            ACCUM:begin
                accumulator<=accumulator+term;
                if(index==7)state<=SIGN;
                else begin index<=index+1'b1;state<=PART;end
            end
            SIGN:begin result<=negative?-$signed(accumulator):$signed(accumulator);state<=RESULT;end
            RESULT:if(out_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
