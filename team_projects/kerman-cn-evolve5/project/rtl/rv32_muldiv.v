`timescale 1ns/1ps
// One outstanding operation. Operands are captured once; response stays stable
// until consumed. Reset/kill discards any in-flight operation and response.
// Four multiply variants share ONE unsigned 32x32 product. Signed high halves
// are corrected modulo 2^32, avoiding a separate signed 33x33 multiplier.
module rv32_muldiv #(parameter FAST_MUL=0) (
    input wire clk,rst,kill,
    input wire req_valid, output wire req_ready,
    input wire [2:0] req_op,
    input wire [31:0] req_a,req_b,
    output wire rsp_valid,input wire rsp_ready,
    output reg [31:0] result
);
    localparam IDLE=0,MUL_PRODUCT=1,MUL_CORRECT=2,DIVIDE=3,DONE=4;
    reg [2:0] state;
    reg [2:0] op;
    reg [31:0] a,b;
    reg [63:0] product;
    reg a_negative,b_negative;
    reg [31:0] quotient,remainder,divisor;
    reg quotient_negative,remainder_negative;
    reg [5:0] steps;
    wire signed_div=(req_op==3'd4 || req_op==3'd6);
    wire [31:0] abs_a=signed_div && req_a[31] ? 32'b0-req_a : req_a;
    wire [31:0] abs_b=signed_div && req_b[31] ? 32'b0-req_b : req_b;
    wire [32:0] trial={remainder,quotient[31]};
    wire subtract=trial>={1'b0,divisor};
    wire [32:0] next_remainder=subtract ? trial-{1'b0,divisor} : trial;
    wire [31:0] next_quotient={quotient[30:0],subtract};
    wire [31:0] multiply_a=FAST_MUL?req_a:a;
    wire [31:0] multiply_b=FAST_MUL?req_b:b;
    wire [63:0] unsigned_product=multiply_a*multiply_b;
    wire [31:0] signed_high=product[63:32]-(a_negative?b:32'b0)-(b_negative?a:32'b0);
    assign req_ready=(state==IDLE) && !rst && !kill;
    assign rsp_valid=(state==DONE) && !rst && !kill;
    always @(posedge clk) begin
        if(rst || kill) begin
            state<=IDLE; result<=0; op<=0; a<=0; b<=0; product<=0;
            a_negative<=0; b_negative<=0; quotient<=0; remainder<=0; divisor<=0;
            quotient_negative<=0; remainder_negative<=0; steps<=0;
        end else case(state)
            IDLE: if(req_valid) begin
                op<=req_op; a<=req_a; b<=req_b;
                if(!req_op[2]) begin
                    a_negative<=(req_op==1 || req_op==2) && req_a[31];
                    b_negative<=(req_op==1) && req_b[31];
                    if(FAST_MUL) begin
                        product<=unsigned_product;
                        if(req_op==0)begin result<=unsigned_product[31:0];state<=DONE;end
                        else state<=MUL_CORRECT;
                    end else state<=MUL_PRODUCT;
                end else if(req_b==0) begin
                    result<=req_op[1]?req_a:32'hffffffff; state<=DONE;
                end else if(signed_div && req_a==32'h80000000 && req_b==32'hffffffff) begin
                    result<=req_op[1]?32'b0:32'h80000000; state<=DONE;
                end else begin
                    quotient<=abs_a; divisor<=abs_b; remainder<=0; steps<=32;
                    quotient_negative<=signed_div && (req_a[31]^req_b[31]);
                    remainder_negative<=signed_div && req_a[31];
                    state<=DIVIDE;
                end
            end
            MUL_PRODUCT: begin product<=unsigned_product; state<=MUL_CORRECT; end
            MUL_CORRECT: begin result<=op==0?product[31:0]:signed_high; state<=DONE; end
            DIVIDE: begin
                quotient<=next_quotient; remainder<=next_remainder[31:0]; steps<=steps-1'b1;
                if(steps==1) begin
                    result<=op[1] ? (remainder_negative?32'b0-next_remainder[31:0]:next_remainder[31:0]) :
                                    (quotient_negative?32'b0-next_quotient:next_quotient);
                    state<=DONE;
                end
            end
            DONE: if(rsp_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
