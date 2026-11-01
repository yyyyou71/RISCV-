`default_nettype none
// Preserve the first pixel and extend a short DE interval into horizontal blanking.
// VS/DE/RGB share one registered stream, consumed by both raw capture and AI.
// A line must leave enough blanking clocks to emit OUT_PIX pixels before the next DE.
module hdmi_line_pad #(
    parameter integer OUT_PIX=1920
)(
    input wire clk,rst_n,vs,de,
    input wire [23:0] rgb,
    output reg out_vs,out_de,
    output reg [23:0] out_rgb
);
    (* ASYNC_REG="TRUE" *) reg [1:0] pixel_reset_sync;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)pixel_reset_sync<=0;
        else pixel_reset_sync<={pixel_reset_sync[0],1'b1};
    wire pixel_reset_n=pixel_reset_sync[1];
    reg old_vs,old_de,emitting;
    reg [11:0] emitted;
    always @(posedge clk or negedge pixel_reset_n)begin
        if(!pixel_reset_n)begin
            old_vs<=0;old_de<=0;emitting<=0;emitted<=0;
            out_vs<=0;out_de<=0;out_rgb<=0;
        end else begin
            old_vs<=vs;old_de<=de;
            out_vs<=vs;out_de<=0;out_rgb<=0;
            if(vs&&!old_vs)begin
                emitting<=0;emitted<=0;
            end else if(de&&!old_de)begin
                emitting<=OUT_PIX>1;emitted<=1;
                out_de<=1;out_rgb<=rgb;
            end else if(emitting)begin
                out_de<=1;out_rgb<=de ? rgb:24'b0;
                emitted<=emitted+1'b1;
                if(emitted==OUT_PIX-1)emitting<=0;
            end
        end
    end
endmodule
`default_nettype wire
