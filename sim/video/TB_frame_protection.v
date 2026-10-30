`timescale 1ns/1ps
module TB_frame_protection;
    reg wr_clk=0,core_clk=0,rst_n=0,en=0;
    always #3 wr_clk=~wr_clk;
    always #4 core_clk=~core_clk;
    reg [15:0] pixel=0;
    reg [4:0] protect=0;
    wire [4:0] done;
    wire [159:0] ids;
    wire [2:0] slot;
    wire active,full;
    wire [27:0] awaddr;
    wire awvalid,awap;
    wire [3:0] awlen;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg sending=0;
    integer delay=0,beat=0,aw_count=0,cycles=0,before_drop;
    reg [27:0] address=0;
    reg [127:0] first_word=0,snapshot=0;
    wire awready=!sending;
    wire wready=sending&&delay==0&&cycles%3!=0;
    wire wlast=wready&&beat==15;
    ddr3_write_ctrl_lite #(.H_ACTIVE(128),.V_ACTIVE(4)) dut (
        .wr_clk(wr_clk),.core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(1'b1),
        .fifo_wr_en(en),.fifo_wr_data(pixel),.fifo_almost_full(full),
        .protect_mask(protect),.capture_ok(1'b1),.frame_ids(ids),.write_active(active),
        .axi_awaddr(awaddr),.axi_awuser_ap(awap),.axi_awlen(awlen),.axi_awvalid(awvalid),
        .axi_awready(awready),.axi_wdata(wdata),.axi_wstrb(wstrb),.axi_wready(wready),.axi_wusero_last(wlast),
        .frame_done(done),.frame_consumed(1'b0),.consumed_frame_id(3'd0),.wr_frame_id(slot),.dbg_sof_seen());
    always @(posedge core_clk)if(rst_n)begin
        cycles<=cycles+1;
        if(awvalid&&awready)begin
            if(protect[awaddr[24:22]])$fatal(1,"protected slot overwritten");
            if(awlen!=15)$fatal(1,"video burst length changed");
            address<=awaddr;sending<=1;delay<=3;beat<=0;aw_count<=aw_count+1;
        end
        if(delay>0)delay<=delay-1;
        if(wready)begin
            if(address==0 && beat==0)first_word<=wdata;
            if(wstrb!=16'hffff)$fatal(1,"video byte enables changed");
            if(wlast)begin sending<=0;beat<=0;end else beat<=beat+1;
        end
    end
    task send_frame;input integer frame;integer n;begin
        for(n=0;n<512;n=n+1)begin
            @(negedge wr_clk);en=1;pixel=n==0 ? 16'h0001:16'(((frame+1)<<8)|(n&254));
        end
        @(negedge wr_clk);en=0;
        repeat(400)@(negedge core_clk);
    end endtask
    initial begin
        repeat(6)@(negedge core_clk);rst_n=1;
        send_frame(0);send_frame(1);
        if(!done[0]||ids[31:0]!=0)$fatal(1,"first frame completion/id");
        protect=1;snapshot=first_word;
        send_frame(2);send_frame(3);send_frame(4);send_frame(5);send_frame(6);send_frame(7);
        if(first_word!==snapshot||!done[0]||ids[31:0]!=0)$fatal(1,"held frame corrupted");
        protect=31;before_drop=aw_count;
        send_frame(8);send_frame(9);
        if(aw_count!=before_drop)$fatal(1,"full pool did not drop input");
        protect=1;send_frame(10);send_frame(11);
        if(aw_count<=before_drop||first_word!==snapshot)$fatal(1,"resume or retained frame failed");
        $display("PASS frame protection: retained slot/data/id, wrap skip, full-pool drop, resume AW=%0d",aw_count);$finish;
    end
    initial begin #500000;$fatal(1,"protection timeout");end
endmodule
