`default_nettype none
// Eight pixels per cycle, three registered stages. First box wins overlaps;
// software supplies boxes in descending confidence order. Inclusive bounds.
module rgb565_box_overlay #(
    parameter integer BOXES=16,WIDTH=1920,HEIGHT=1080
)(
    input wire clk,rst_n,frame_start,in_valid,
    input wire [127:0] in_data,
    input wire [4:0] box_count,
    input wire [BOXES*64-1:0] boxes,
    output reg out_valid,
    output reg [127:0] out_data
);
    reg [10:0] x,y;
    reg v0,v1;
    reg [127:0] data0,data1;
    reg [BOXES*8-1:0] hit0;
    reg [31:0] group_valid;
    reg [511:0] group_color;
    integer lane,b,g,k;
    reg found;
    reg [15:0] chosen;
    reg [10:0] px,x0,y0,x1,y1;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            x<=0;y<=0;v0<=0;v1<=0;out_valid<=0;data0<=0;data1<=0;
            hit0<=0;group_valid<=0;group_color<=0;out_data<=0;
        end else if(frame_start)begin
            x<=0;y<=0;v0<=0;v1<=0;out_valid<=0;
        end else begin
            v0<=in_valid;v1<=v0;out_valid<=v1;data0<=in_data;data1<=data0;
            if(in_valid)begin
                if(x==WIDTH-8)begin x<=0;y<=y==HEIGHT-1?11'd0:y+1'b1;end
                else x<=x+11'd8;
            end
            for(b=0;b<BOXES;b=b+1)begin
                x0=boxes[b*64+:11];y0=boxes[b*64+11+:11];
                x1=boxes[b*64+22+:11];y1=boxes[b*64+33+:11];
                for(lane=0;lane<8;lane=lane+1)begin
                    px=x+lane;
                    hit0[b*8+lane]<=b<box_count && px>=x0 && px<=x1 && y>=y0 && y<=y1 &&
                        (px==x0 || px==x0+1 || px==x1 || px+1==x1 ||
                         y==y0 || y==y0+1 || y==y1 || y+1==y1);
                end
            end
            for(lane=0;lane<8;lane=lane+1)begin
                for(g=0;g<4;g=g+1)begin
                    found=0;chosen=0;
                    for(k=0;k<4;k=k+1)if(!found && hit0[(g*4+k)*8+lane])begin
                        found=1;chosen=boxes[(g*4+k)*64+44+:16];
                    end
                    group_valid[lane*4+g]<=found;
                    group_color[(lane*4+g)*16+:16]<=chosen;
                end
                found=0;chosen=data1[lane*16+:16];
                for(g=0;g<4;g=g+1)if(!found && group_valid[lane*4+g])begin
                    found=1;chosen=group_color[(lane*4+g)*16+:16];
                end
                out_data[lane*16+:16]<=chosen;
            end
        end
    end
endmodule
`default_nettype wire
