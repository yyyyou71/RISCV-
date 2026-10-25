`timescale 1ns/1ps
// Verification adapter only: deliberately serializes a command into the existing
// randomized word-memory BFM. Production SoC uses the synchronous burst backend.
module burst_word_test_adapter (
    input wire clk,rst,cv,cw,
    input wire [31:0] ca,cd,
    input wire [3:0] cs,
    input wire [7:0] cl,
    output wire cr,rv,re,rl,
    output wire [31:0] rd,
    input wire rr,
    output wire mv,mw,
    output wire [31:0] ma,md,
    output wire [3:0] ms,
    input wire mr,me,
    input wire [31:0] mdata
);
    reg [1:0] state=0;
    reg write_op,error_q;
    reg [31:0] address,data_q,wd;
    reg [3:0] strobes;
    reg [7:0] length,beat;
    assign cr=!rst && state==0; assign rv=!rst && state==2;
    assign re=error_q; assign rl=beat==length; assign rd=data_q;
    assign mv=!rst && state==1; assign mw=write_op; assign ma=address; assign md=wd; assign ms=strobes;
    always @(posedge clk) begin
        if(rst) begin state<=0; write_op<=0; error_q<=0; address<=0; data_q<=0; wd<=0; strobes<=0; length<=0; beat<=0; end
        else case(state)
            0: if(cv) begin state<=1; write_op<=cw; address<=ca; wd<=cd; strobes<=cs; length<=cl; beat<=0; end
            1: if(mr) begin data_q<=mdata; error_q<=me; state<=2; end
            2: if(rr) begin
                if(rl) state<=0;
                else begin address<=address+4; beat<=beat+1'b1; state<=1; end
            end
        endcase
    end
endmodule
