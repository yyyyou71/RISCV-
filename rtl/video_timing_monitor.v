`default_nettype none
// Observe actual source geometry; do not infer HDMI mode from an expected label.
module video_timing_monitor (
    input wire pixel_clk,clk,rst_n,vs,de,
    output reg shape_ok,
    output reg [31:0] shape,period_ticks
);
    reg old_vs,old_de,toggle,bad_line;
    reg [15:0] line_pixels,max_pixels,lines;
    reg [31:0] pixel_shape;
    (* ASYNC_REG="TRUE" *) reg meta,synced;
    reg seen,last;
    reg [31:0] timer;
    (* ASYNC_REG="TRUE" *) reg [1:0] pixel_reset_sync;
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n)pixel_reset_sync<=0;else pixel_reset_sync<={pixel_reset_sync[0],1'b1};
    wire pixel_reset_n=pixel_reset_sync[1];
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if(!pixel_reset_n) begin
            old_vs<=0;old_de<=0;toggle<=0;line_pixels<=0;max_pixels<=0;lines<=0;
            pixel_shape<=0;shape_ok<=0;bad_line<=0;
        end else begin
            old_vs<=vs;old_de<=de;
            if(de) line_pixels<=line_pixels+1'b1;
            if(old_de && !de) begin
                if(line_pixels!=1920)bad_line<=1;
                if(line_pixels>max_pixels)max_pixels<=line_pixels;
                line_pixels<=0;lines<=lines+1'b1;
            end
            if(vs && !old_vs) begin
                pixel_shape<={lines,max_pixels};
                shape_ok<=lines==1080 && max_pixels==1920 && !bad_line;
                bad_line<=0;
                toggle<=!toggle;line_pixels<=0;max_pixels<=0;lines<=0;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin meta<=0;synced<=0;last<=0;seen<=0;timer<=0;shape<=0;period_ticks<=0;end
        else begin
            meta<=toggle;synced<=meta;timer<=timer+1'b1;
            if(synced!=last)begin
                last<=synced;shape<=pixel_shape;timer<=0;seen<=1;
                if(seen)period_ticks<=timer+1'b1;
            end
        end
    end
endmodule
`default_nettype wire
