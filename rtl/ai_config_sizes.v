`timescale 1ns/1ps
`default_nettype none
// Configuration-only arithmetic. One shared serial multiplier replaces the
// cascaded wide products on the CPU->DDR command path. All results retain the
// original unsigned modulo-2^64 semantics, including malformed commands.
module ai_config_sizes #(
    parameter integer ACT_WIDTH=16
)(
    input wire clk,rst_n,start,
    input wire [15:0] in_h,in_w,
    input wire [31:0] ci_pitch,co_pitch,out_h,out_w,out_pitch,cat_b_pitch,
    input wire [1:0] kernel,
    input wire quantized,
    output reg done,
    output reg [63:0] input_size,weight_size,output_size,add_size,cat_b_size,cat_o_size
);
    localparam [1:0] IDLE=0,LAUNCH=1,MULTIPLY=2,STORE=3;
    reg [1:0] state;
    reg [2:0] phase;
    reg [5:0] bit_count;
    reg [63:0] area,output_area,weight_planes,accumulator,multiplicand;
    reg [31:0] multiplier;
    reg [63:0] operand_a;
    reg [31:0] operand_b;
    wire [63:0] sum=accumulator+(multiplier[0]?multiplicand:64'd0);
    wire [31:0] kernel_squared=kernel==3?32'd9:kernel==2?32'd4:kernel==1?32'd1:32'd0;
    always @* begin
        operand_a=0;operand_b=0;
        case(phase)
            0:begin operand_a={48'd0,in_h};operand_b={16'd0,in_w};end
            1:begin operand_a=area;operand_b=ci_pitch;end
            2:begin operand_a={32'd0,co_pitch};operand_b=kernel_squared;end
            3:begin operand_a=weight_planes;operand_b=ci_pitch;end
            4:begin operand_a={32'd0,out_h};operand_b=out_w;end
            5:begin operand_a=output_area;operand_b=out_pitch;end
            6:begin operand_a=area;operand_b=cat_b_pitch;end
            7:begin operand_a=area;operand_b=out_pitch;end
        endcase
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;phase<=0;bit_count<=0;done<=0;
            area<=0;output_area<=0;weight_planes<=0;accumulator<=0;multiplicand<=0;multiplier<=0;
            input_size<=0;weight_size<=0;output_size<=0;add_size<=0;cat_b_size<=0;cat_o_size<=0;
        end else case(state)
            IDLE:if(start)begin done<=0;phase<=0;state<=LAUNCH;end
            LAUNCH:begin
                accumulator<=0;multiplicand<=operand_a;multiplier<=operand_b;
                bit_count<=0;state<=MULTIPLY;
            end
            MULTIPLY:begin
                accumulator<=sum;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
                if(bit_count==31)state<=STORE;else bit_count<=bit_count+1'b1;
            end
            STORE:begin
                case(phase)
                    0:area<=accumulator;
                    1:begin
                        input_size<=ACT_WIDTH==16?accumulator<<1:accumulator;
                        add_size<=accumulator<<1;
                    end
                    2:weight_planes<=accumulator;
                    3:weight_size<=accumulator;
                    4:output_area<=accumulator;
                    5:output_size<=quantized?(ACT_WIDTH==16?accumulator<<1:accumulator):accumulator<<3;
                    6:cat_b_size<=accumulator<<1;
                    7:cat_o_size<=accumulator<<1;
                endcase
                if(phase==7)begin done<=1;state<=IDLE;end
                else begin phase<=phase+1'b1;state<=LAUNCH;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
