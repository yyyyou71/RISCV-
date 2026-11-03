`default_nettype none
// Transactional 384x216 adaptive average pool. Coordinates advance only on
// accepted pixels. One mean may be in flight; all downstream stalls are legal.
module rgb888_pool96_stream (
    input wire clk,rst_n,start,cancel,
    input wire in_valid,
    output wire in_ready,
    input wire [23:0] rgb,
    output wire out_valid,
    input wire out_ready,
    output wire [127:0] out_data,
    output wire out_last,
    output reg done,error,
    output reg [15:0] out_beats
);
    reg active,input_done,have_pixel,second,last_pixel;
    reg [8:0] x,y,v_start,v_end;
    reg [6:0] ox,oy;
    reg [9:0] hr,hg,hb;
    reg [23:0] pixel;
    wire mean_valid,mean_busy;
    wire [23:0] mean_rgb;
    wire [6:0] mx,my;
    wire [47:0] accumulated;
    wire take=in_valid&&in_ready;
    wire bin_end=take&&x[1:0]==3;
    wire row_end=y==v_end-1'b1;
    wire overlap_next=oy[1:0]!=3;
    wire [15:0] lr={6'b0,hr}+{8'b0,rgb[23:16]};
    wire [15:0] lg={6'b0,hg}+{8'b0,rgb[15:8]};
    wire [15:0] lb={6'b0,hb}+{8'b0,rgb[7:0]};
    wire [15:0] sr=y==v_start?lr:accumulated[15:0]+lr;
    wire [15:0] sg=y==v_start?lg:accumulated[31:16]+lg;
    wire [15:0] sb=y==v_start?lb:accumulated[47:32]+lb;
    wire [47:0] next_sum=row_end?(overlap_next?{lb,lg,lr}:48'b0):{sb,sg,sr};
    assign in_ready=active&&!input_done&&!mean_busy&&!have_pixel&&!cancel;
    assign out_valid=active&&have_pixel&&!cancel;
    assign out_data=second?128'b0:{80'b0,8'b0,pixel[7:0],8'b0,pixel[15:8],8'b0,pixel[23:16]};
    assign out_last=out_valid&&second&&last_pixel;
    pool_sum_ram u_sums(.clk(clk),.rst_n(rst_n),.wr_en(bin_end),
        .wr_addr(ox),.rd_addr(ox),.wr_data(next_sum),.rd_data(accumulated));
    rgb_mean12 u_mean(.clk(clk),.rst_n(rst_n),.clear(!active||cancel),
        .in_valid(bin_end&&row_end),.sum_r(sr),.sum_g(sg),.sum_b(sb),
        .in_x(ox),.in_y(oy),.out_valid(mean_valid),.out_rgb(mean_rgb),
        .out_x(mx),.out_y(my),.busy(mean_busy));
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            active<=0;input_done<=0;have_pixel<=0;second<=0;last_pixel<=0;
            x<=0;y<=0;ox<=0;oy<=0;v_start<=0;v_end<=3;
            hr<=0;hg<=0;hb<=0;pixel<=0;done<=0;error<=0;out_beats<=0;
        end else begin
            done<=0;
            if(start&&!active)begin
                active<=1;input_done<=0;have_pixel<=0;second<=0;last_pixel<=0;
                x<=0;y<=0;ox<=0;oy<=0;v_start<=0;v_end<=3;
                hr<=0;hg<=0;hb<=0;out_beats<=0;error<=0;
            end else if(cancel&&active)begin
                active<=0;have_pixel<=0;error<=1;done<=1;
            end else if(active)begin
                if(take)begin
                    if(x[1:0]==3)begin
                        hr<=0;hg<=0;hb<=0;ox<=ox==95?7'd0:ox+1'b1;
                    end else begin hr<=lr[9:0];hg<=lg[9:0];hb<=lb[9:0];end
                    if(x==383)begin
                        x<=0;y<=y+1'b1;
                        if(row_end)begin
                            oy<=oy+1'b1;v_start<=v_end-(overlap_next?9'd1:9'd0);
                            v_end<=v_end+(overlap_next?9'd2:9'd3);
                        end
                        if(y==215)input_done<=1;
                    end else x<=x+1'b1;
                end
                if(mean_valid)begin pixel<=mean_rgb;have_pixel<=1;second<=0;last_pixel<=mx==95&&my==95;end
                if(out_valid&&out_ready)begin
                    out_beats<=out_beats+1'b1;
                    if(second)begin have_pixel<=0;second<=0;end else second<=1;
                end
                if(input_done&&!mean_busy&&!have_pixel)begin
                    active<=0;done<=1;error<=out_beats!=18432;
                end
            end
        end
    end
endmodule

// Exact division by 12 for sums 0..3060, with nearest-even rounding.
// For n<=765, floor(n/3) = (n*683)>>11. Divide sum by 4 first.
module rgb_mean12 (
    input wire clk,rst_n,clear,in_valid,
    input wire [15:0] sum_r,sum_g,sum_b,
    input wire [6:0] in_x,in_y,
    output reg out_valid,
    output reg [23:0] out_rgb,
    output reg [6:0] out_x,out_y,
    output wire busy
);
    reg v1,v2;
    reg [19:0] pr,pg,pb;
    reg [15:0] saved_r,saved_g,saved_b;
    reg [7:0] qr,qg,qb;
    reg [3:0] rr,rg,rb;
    reg [6:0] x1,y1,x2,y2;
    function [19:0] reciprocal3;
        input [9:0] n;reg [19:0] w;
        begin w={10'b0,n};reciprocal3=(w<<9)+(w<<7)+(w<<5)+(w<<3)+(w<<1)+w;end
    endfunction
    function [15:0] times12;
        input [7:0] q;reg [15:0] w;
        begin w={8'b0,q};times12=(w<<3)+(w<<2);end
    endfunction
    function [7:0] rounded;
        input [7:0] q;input [3:0] r;
        begin rounded=q+{7'b0,(r>6||(r==6&&q[0]))};end
    endfunction
    assign busy=v1||v2||out_valid;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            v1<=0;v2<=0;out_valid<=0;out_rgb<=0;out_x<=0;out_y<=0;
            pr<=0;pg<=0;pb<=0;saved_r<=0;saved_g<=0;saved_b<=0;
            qr<=0;qg<=0;qb<=0;rr<=0;rg<=0;rb<=0;x1<=0;y1<=0;x2<=0;y2<=0;
        end else if(clear)begin v1<=0;v2<=0;out_valid<=0;end
        else begin
            v1<=in_valid;v2<=v1;out_valid<=v2;
            if(in_valid)begin
                pr<=reciprocal3(sum_r[11:2]);pg<=reciprocal3(sum_g[11:2]);pb<=reciprocal3(sum_b[11:2]);
                saved_r<=sum_r;saved_g<=sum_g;saved_b<=sum_b;x1<=in_x;y1<=in_y;
            end
            if(v1)begin
                qr<=pr[18:11];qg<=pg[18:11];qb<=pb[18:11];
                rr<=saved_r-times12(pr[18:11]);rg<=saved_g-times12(pg[18:11]);rb<=saved_b-times12(pb[18:11]);
                x2<=x1;y2<=y1;
            end
            if(v2)begin out_rgb<={rounded(qr,rr),rounded(qg,rg),rounded(qb,rb)};out_x<=x2;out_y<=y2;end
        end
    end
endmodule
`default_nettype wire
