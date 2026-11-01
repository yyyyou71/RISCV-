`timescale 1ns/1ps
module TB_frame_protection;
    reg wr_clk=0,core_clk=0,rst_n=0,en=0;
    always #3 wr_clk=~wr_clk;
    always #4 core_clk=~core_clk;
    reg [15:0] pixel=0;
    reg [4:0] protect=0;
    wire [4:0] cpu_hold;
    wire [4:0] protection=protect|cpu_hold;
    reg cpu_we=0;
    reg [31:0] cpu_command=0;
    wire [31:0] cpu_status;
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
        .protect_mask(protection),.capture_ok(1'b1),.frame_ids(ids),.write_active(active),
        .axi_awaddr(awaddr),.axi_awuser_ap(awap),.axi_awlen(awlen),.axi_awvalid(awvalid),
        .axi_awready(awready),.axi_wdata(wdata),.axi_wstrb(wstrb),.axi_wready(wready),.axi_wusero_last(wlast),
        .frame_done(done),.frame_consumed(1'b0),.consumed_frame_id(3'd0),.wr_frame_id(slot),.dbg_sof_seen());
    always @(posedge core_clk)if(rst_n)begin
        cycles<=cycles+1;
        if(awvalid&&awready)begin
            if(protection[awaddr[24:22]])$fatal(1,"protected slot overwritten");
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
    frame_mailbox mailbox(.clk(wr_clk),.core_clk(core_clk),.rst_n(rst_n),
        .dev_we(cpu_we),.dev_addr_wr(32'h30600),.dev_addr_rd(32'h30604),.dev_wdata(cpu_command),
        .read_data(cpu_status),.available(done),.frame_ids(ids),.wr_slot(slot),.wr_active(active),
        .ddr_ready(1'b1),.arb_fault(1'b0),.video_shape(32'b0),.video_period(32'b0),.hold_mask(cpu_hold));
    task command;input [31:0] value;begin
        @(negedge wr_clk);cpu_command=value;cpu_we=1;
        @(negedge wr_clk);cpu_we=0;#1;
        while(cpu_status[0])@(negedge wr_clk);
    end endtask
    task send_frame;input integer frame;integer n;begin
        for(n=0;n<512;n=n+1)begin
            @(negedge wr_clk);en=1;pixel=n==0 ? 16'h0001:16'(((frame+1)<<8)|(n&254));
        end
        @(negedge wr_clk);en=0;
        repeat(400)@(negedge core_clk);
    end endtask
    wire source_fault,frame_begin;
    wire [31:0] source_next_id,frame_begin_id;
    integer observed_frames=0;
    assign source_fault=dut.source_fault;
    assign frame_begin=dut.frame_begin;
    assign source_next_id=dut.source_next_id;
    assign frame_begin_id=dut.frame_begin_id;
    always @(posedge core_clk)if(rst_n&&frame_begin)begin
        if(frame_begin_id!=observed_frames)$fatal(1,"source/write frame IDs diverged");
        observed_frames<=observed_frames+1;
    end
    integer held_slot,j;
    reg [31:0] held_id;
    initial begin
        repeat(6)@(negedge core_clk);rst_n=1;
        wait(dut.pixel_reset_n && dut.core_reset_n);
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
        protect=0;
        fork send_frame(12);command(1);join
        if(cpu_hold==0||cpu_status[3])$fatal(1,"concurrent CPU lease failed");
        held_slot=0;
        for(j=0;j<5;j=j+1)if(cpu_hold[j])held_slot=j;
        held_id=ids[held_slot*32+:32];
        send_frame(13);send_frame(14);send_frame(15);send_frame(16);send_frame(17);send_frame(18);
        if(ids[held_slot*32+:32]!==held_id)$fatal(1,"leased metadata overwritten after wrap");
        command(2);if(cpu_hold!=0)$fatal(1,"CPU lease did not release");
        if(source_fault||source_next_id!=19||observed_frames!=19)$fatal(1,"SOF identity changed across dropped frames");
        $display("PASS frame protection: retained slot/data/id, wrap skip, full-pool drop/resume, concurrent mailbox lease AW=%0d",aw_count);$finish;
    end
    initial begin #500000;$fatal(1,"protection timeout");end
endmodule
