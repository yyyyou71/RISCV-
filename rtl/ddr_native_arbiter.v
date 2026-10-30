`default_nettype none
// Two requesters, one native DDR user port. AW/W and AR/R arbitrate independently.
// A grant remains fixed through address backpressure and the entire response.
module ddr_native_arbiter (
    input wire clk,rst_n,
    input wire [55:0] s_awaddr,s_araddr,
    input wire [1:0] s_awvalid,s_arvalid,s_awap,s_arap,
    input wire [7:0] s_awlen,s_arlen,s_awid,s_arid,
    output wire [1:0] s_awready,s_arready,s_wready,s_wlast,s_rvalid,s_rlast,
    output wire [7:0] s_wid,s_rid,
    input wire [255:0] s_wdata,
    input wire [31:0] s_wstrb,
    output wire [255:0] s_rdata,
    output wire [27:0] m_awaddr,m_araddr,
    output wire m_awvalid,m_arvalid,m_awap,m_arap,
    output wire [3:0] m_awlen,m_arlen,m_awid,m_arid,
    input wire m_awready,m_arready,m_wready,m_wlast,m_rvalid,m_rlast,
    input wire [3:0] m_wid,m_rid,
    output wire [127:0] m_wdata,
    output wire [15:0] m_wstrb,
    input wire [127:0] m_rdata,
    output reg fault
);
    reg wl,rl,wo,ro,wa,ra,last_w,last_r;
    reg [3:0] wlen,rlen,wid,rid,wbeat,rbeat;
    wire aw_fire=m_awvalid && m_awready;
    wire ar_fire=m_arvalid && m_arready;
    wire w_owner=wl && (wa || aw_fire);
    wire r_owner=rl && (ra || ar_fire);
    assign m_awaddr=s_awaddr[wo*28 +:28];
    assign m_araddr=s_araddr[ro*28 +:28];
    assign m_awlen=s_awlen[wo*4 +:4];
    assign m_arlen=s_arlen[ro*4 +:4];
    assign m_awid=s_awid[wo*4 +:4];
    assign m_arid=s_arid[ro*4 +:4];
    assign m_awap=s_awap[wo]; assign m_arap=s_arap[ro];
    assign m_awvalid=rst_n && !fault && wl && !wa && s_awvalid[wo];
    assign m_arvalid=rst_n && !fault && rl && !ra && s_arvalid[ro];
    assign s_awready=m_awvalid ? (2'b01<<wo)&{2{m_awready}}:2'b0;
    assign s_arready=m_arvalid ? (2'b01<<ro)&{2{m_arready}}:2'b0;
    assign m_wdata=s_wdata[wo*128 +:128];
    assign m_wstrb=(w_owner && !fault) ? s_wstrb[wo*16 +:16]:16'b0;
    assign s_wready=(w_owner && !fault) ? (2'b01<<wo)&{2{m_wready}}:2'b0;
    assign s_wlast=s_wready&{2{m_wlast}};
    assign s_wid={2{m_wid}};
    assign s_rvalid=(r_owner && !fault) ? (2'b01<<ro)&{2{m_rvalid}}:2'b0;
    assign s_rlast=s_rvalid&{2{m_rlast}};
    assign s_rdata={2{m_rdata}}; assign s_rid={2{m_rid}};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            wl<=0;rl<=0;wo<=0;ro<=0;wa<=0;ra<=0;last_w<=1;last_r<=1;
            wlen<=0;rlen<=0;wid<=0;rid<=0;wbeat<=0;rbeat<=0;fault<=0;
        end else if(!fault) begin
            if(!wl && |s_awvalid) begin
                wl<=1;wo<=(&s_awvalid) ? !last_w:s_awvalid[1];
            end
            if(!rl && |s_arvalid) begin
                rl<=1;ro<=(&s_arvalid) ? !last_r:s_arvalid[1];
            end
            if(aw_fire) begin wa<=1;wlen<=m_awlen;wid<=m_awid;end
            if(ar_fire) begin ra<=1;rlen<=m_arlen;rid<=m_arid;end
            if(m_wready && w_owner) begin
                if(m_wid!=(aw_fire?m_awid:wid) ||
                   m_wlast!=(wbeat==(aw_fire?m_awlen:wlen))) fault<=1;
                if(m_wlast) begin wl<=0;wa<=0;last_w<=wo;wbeat<=0;end
                else wbeat<=wbeat+1'b1;
            end
            if(m_rvalid && r_owner) begin
                if(m_rid!=(ar_fire?m_arid:rid) ||
                   m_rlast!=(rbeat==(ar_fire?m_arlen:rlen))) fault<=1;
                if(m_rlast) begin rl<=0;ra<=0;last_r<=ro;rbeat<=0;end
                else rbeat<=rbeat+1'b1;
            end
            if((m_wready && !w_owner) || (m_rvalid && !r_owner)) fault<=1;
        end
    end
endmodule
`default_nettype wire
