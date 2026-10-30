`default_nettype none
// One-shot 1920x1080 RGB888 -> 96x96 HWC-align16 INT16 stream.
// start arms the next rising VS; source_frame_id is sampled at that VS.
// done terminates a transaction on success OR error. Consumers must discard
// every partial tensor when error=1, including beats already transferred.
module rgb888_pool96 #(
    parameter integer TIMEOUT_CYCLES=8000000
)(
    input wire clk,rst_n,start,cancel,
    input wire vs,de,
    input wire [23:0] rgb,
    input wire [31:0] source_frame_id,
    output wire ready,busy,
    output reg frame_start,done,error,
    output reg [3:0] error_code,
    output reg [31:0] result_frame_id,
    output wire out_valid,
    input wire out_ready,
    output wire [127:0] out_data,
    output wire out_last,
    output reg [15:0] out_beats
);
    localparam [1:0] IDLE=0,WAIT_VS=1,CAPTURE=2,DRAIN=3;
    localparam [3:0] E_SHAPE=1,E_BACKPRESSURE=2,E_COUNT=3,E_TIMEOUT=4,E_CANCEL=5;
    reg [1:0] state;
    reg old_vs,old_de;
    reg [31:0] timer;
    reg [11:0] px,py,v_start,v_end;
    reg [4:0] hx;
    reg [6:0] ox,oy;
    reg [12:0] horizontal_r,horizontal_g,horizontal_b;
    wire edge_vs=vs&&!old_vs;
    wire capturing=state==CAPTURE;
    wire active=capturing||state==DRAIN;
    assign ready=state==IDLE;
    assign busy=!ready;
    wire [15:0] line_r={3'b0,horizontal_r}+{8'b0,rgb[23:16]};
    wire [15:0] line_g={3'b0,horizontal_g}+{8'b0,rgb[15:8]};
    wire [15:0] line_b={3'b0,horizontal_b}+{8'b0,rgb[7:0]};
    wire [47:0] accumulated;
    wire [15:0] sum_r=py==v_start ? line_r:accumulated[15:0]+line_r;
    wire [15:0] sum_g=py==v_start ? line_g:accumulated[31:16]+line_g;
    wire [15:0] sum_b=py==v_start ? line_b:accumulated[47:32]+line_b;
    wire bin_end=capturing&&de&&!edge_vs&&!cancel&&px<1920&&py<1080&&hx==19;
    wire row_end=py==v_end-1'b1;
    // Three of every four output boundaries share the last input row.
    wire overlap_next=oy[1:0]!=3;
    wire [47:0] next_sums=row_end ? (overlap_next ? {line_b,line_g,line_r}:48'b0):{sum_b,sum_g,sum_r};
    pool_sum_ram u_sums(.clk(clk),.rst_n(rst_n),.wr_en(bin_end),.wr_addr(ox),
        .rd_addr(ox),.wr_data(next_sums),.rd_data(accumulated));
    wire mean_valid,mean_busy;
    wire [23:0] mean_rgb;
    wire [6:0] mean_x,mean_y;
    rgb_mean240 u_mean(.clk(clk),.rst_n(rst_n),.clear(!active||cancel),
        .in_valid(bin_end&&row_end),.sum_r(sum_r),.sum_g(sum_g),.sum_b(sum_b),
        .in_x(ox),.in_y(oy),.out_valid(mean_valid),.out_rgb(mean_rgb),
        .out_x(mean_x),.out_y(mean_y),.busy(mean_busy));
    reg have_pixel,second,last_pixel;
    reg [23:0] packed_rgb;
    assign out_valid=active&&have_pixel&&!cancel;
    assign out_data=second ? 128'b0:{80'b0,8'b0,packed_rgb[7:0],8'b0,packed_rgb[15:8],8'b0,packed_rgb[23:16]};
    assign out_last=have_pixel&&second&&last_pixel;
    wire transfer=out_valid&&out_ready;
    wire pixel_room=!have_pixel||(transfer&&second);
    wire overflow=active&&mean_valid&&!pixel_room;
    wire shape_complete=!de && ((py==1080&&px==0) || (old_de&&py==1079&&px==1920));
    wire timeout=state!=IDLE && timer>=TIMEOUT_CYCLES-1;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;old_vs<=0;old_de<=0;timer<=0;frame_start<=0;done<=0;error<=0;error_code<=0;
            px<=0;py<=0;v_start<=0;v_end<=12;hx<=0;ox<=0;oy<=0;
            horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;
            have_pixel<=0;second<=0;last_pixel<=0;packed_rgb<=0;out_beats<=0;result_frame_id<=0;
        end else begin
            old_vs<=vs;old_de<=de;frame_start<=0;done<=0;
            if(state==IDLE)timer<=0;else timer<=timer+1'b1;
            if(transfer)begin
                out_beats<=out_beats+1'b1;
                if(second)begin have_pixel<=0;second<=0;end else second<=1;
            end
            if(active&&mean_valid&&pixel_room)begin
                packed_rgb<=mean_rgb;last_pixel<=mean_x==95&&mean_y==95;have_pixel<=1;second<=0;
            end
            if(state==IDLE)begin
                have_pixel<=0;
                if(start)begin
                    state<=WAIT_VS;timer<=0;error<=0;error_code<=0;out_beats<=0;
                    px<=0;py<=0;hx<=0;ox<=0;oy<=0;v_start<=0;v_end<=12;
                    horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;second<=0;
                end
            end else if(cancel||timeout||overflow)begin
                state<=IDLE;done<=1;error<=1;have_pixel<=0;
                error_code<=cancel ? E_CANCEL:(timeout ? E_TIMEOUT:E_BACKPRESSURE);
            end else case(state)
                WAIT_VS: if(edge_vs)begin
                    result_frame_id<=source_frame_id;timer<=0;
                    if(de)begin state<=IDLE;done<=1;error<=1;error_code<=E_SHAPE;end
                    else begin state<=CAPTURE;frame_start<=1;end
                end
                CAPTURE: begin
                    if(edge_vs)begin
                        if(shape_complete)begin state<=DRAIN;timer<=0;end
                        else begin state<=IDLE;done<=1;error<=1;error_code<=E_SHAPE;have_pixel<=0;end
                    end else if(de)begin
                        if(px>=1920||py>=1080)begin
                            state<=IDLE;done<=1;error<=1;error_code<=E_SHAPE;have_pixel<=0;
                        end else begin
                            px<=px+1'b1;
                            if(hx==19)begin
                                hx<=0;ox<=ox==95 ? 7'd0:ox+1'b1;
                                horizontal_r<=0;horizontal_g<=0;horizontal_b<=0;
                            end else begin
                                hx<=hx+1'b1;horizontal_r<=line_r[12:0];
                                horizontal_g<=line_g[12:0];horizontal_b<=line_b[12:0];
                            end
                        end
                    end else if(old_de)begin
                        if(px!=1920)begin
                            state<=IDLE;done<=1;error<=1;error_code<=E_SHAPE;have_pixel<=0;
                        end else begin
                            px<=0;py<=py+1'b1;
                            if(row_end)begin
                                oy<=oy+1'b1;v_start<=v_end-(overlap_next?12'd1:12'd0);
                                v_end<=v_end+(overlap_next?12'd11:12'd12);
                            end
                        end
                    end
                end
                DRAIN: if(!mean_busy&&!have_pixel)begin
                    state<=IDLE;done<=1;
                    if(out_beats!=18432)begin error<=1;error_code<=E_COUNT;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
