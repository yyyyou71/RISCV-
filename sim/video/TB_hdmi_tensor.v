`timescale 1ns/1ps
module TB_hdmi_tensor;
    reg clk=0,core_clk=0,pixel_clk=0,rst_n=0;
    always #20 clk=~clk;
    always #3 core_clk=~core_clk;
    always #4 pixel_clk=~pixel_clk;
    reg we=0;reg [7:0] wa=0,ra=4;reg [31:0] wd=0;
    wire [31:0] rd;
    reg vs=0,de=0;reg [23:0] rgb=24'h1155aa;
    reg [31:0] next_id=0;
    reg raw_begin=0,raw_end=0,raw_ok=1,raw_accepted=1;
    reg [31:0] begin_id=0,end_id=0;
    wire [4:0] held;
    wire fault;
    wire [27:0] taw;
    wire tav,tap,tar,twr,twl;wire [3:0] tal,tid,twi;
    wire [127:0] twd;wire [15:0] tws;
    hdmi_tensor_capture #(.CORE_TIMEOUT_CYCLES(8000000)) dut(
        .clk(clk),.core_clk(core_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
        .ddr_ready(1'b1),.shared_fault(1'b0),.dev_we(we),.dev_addr_wr(wa),.dev_addr_rd(ra),
        .dev_wdata(wd),.read_data(rd),.vs(vs),.de(de),.rgb(rgb),.source_ready(1'b1),.source_next_id(next_id),
        .raw_begin(raw_begin),.raw_accepted(raw_accepted),.raw_begin_id(begin_id),.raw_begin_slot(3'd2),
        .raw_end(raw_end),.raw_end_ok(raw_ok),.raw_end_id(end_id),.raw_end_slot(3'd2),
        .hold_mask(held),.fault(fault),.axi_awaddr(taw),.axi_awvalid(tav),.axi_awap(tap),
        .axi_awlen(tal),.axi_awid(tid),.axi_awready(tar),.axi_wready(twr),.axi_wlast(twl),
        .axi_wid(twi),.axi_wdata(twd),.axi_wstrb(tws));

    wire [27:0] iaw,maw;wire iav,iap,mav,map;
    wire [3:0] ial,iid,mal,mid;
    wire [127:0] iwd,mwd;wire [15:0] iws,mws;
    wire [1:0] iar,iarread,iwr,iwl,irvalid,irlast,mar,marread,mwr,mwl,mrvalid,mrlast;
    wire [7:0] iwi,iri,mwi,mri;wire [255:0] ird,mrd;
    wire ifault,mfault;
    reg cpu_pending=0,cpu_active=0,video_pending=0,video_active=0,traffic=1;
    integer cpu_count=0,video_count=0,cycles=0;
    wire native_ar=!sending&&cycles%5!=0;
    wire native_wr=sending&&cycles%7!=0;
    wire native_last=native_wr&&beat==15;
    reg sending=0;
    reg [3:0] owner_id=0;
    integer beat=0,tensor_beats=0,tensor_bursts=0;
    ddr_native_arbiter inner_bus(
        .clk(core_clk),.rst_n(rst_n),
        .s_awaddr({taw,28'h2010000}),.s_araddr(56'b0),.s_awvalid({tav,cpu_pending}),.s_arvalid(2'b0),
        .s_awap({tap,1'b0}),.s_arap(2'b0),.s_awlen({tal,4'd15}),.s_arlen(8'b0),
        .s_awid({tid,4'd1}),.s_arid(8'b0),.s_awready(iar),.s_arready(iarread),
        .s_wready(iwr),.s_wlast(iwl),.s_rvalid(irvalid),.s_rlast(irlast),.s_wid(iwi),.s_rid(iri),
        .s_wdata({twd,128'hcccc}),.s_wstrb({tws,16'hffff}),.s_rdata(ird),
        .m_awaddr(iaw),.m_araddr(),.m_awvalid(iav),.m_arvalid(),.m_awap(iap),.m_arap(),
        .m_awlen(ial),.m_arlen(),.m_awid(iid),.m_arid(),.m_awready(mar[1]),.m_arready(1'b0),
        .m_wready(mwr[1]),.m_wlast(mwl[1]),.m_rvalid(1'b0),.m_rlast(1'b0),.m_wid(mwi[7:4]),
        .m_rid(4'b0),.m_wdata(iwd),.m_wstrb(iws),.m_rdata(128'b0),.fault(ifault));
    assign tar=iar[1];assign twr=iwr[1];assign twl=iwl[1];assign twi=iwi[7:4];
    ddr_native_arbiter outer_bus(
        .clk(core_clk),.rst_n(rst_n),.s_awaddr({iaw,28'h8000}),.s_araddr(56'b0),
        .s_awvalid({iav,video_pending}),.s_arvalid(2'b0),.s_awap({iap,1'b0}),.s_arap(2'b0),
        .s_awlen({ial,4'd15}),.s_arlen(8'b0),.s_awid({iid,4'b0}),.s_arid(8'b0),
        .s_awready(mar),.s_arready(marread),.s_wready(mwr),.s_wlast(mwl),
        .s_rvalid(mrvalid),.s_rlast(mrlast),.s_wid(mwi),.s_rid(mri),
        .s_wdata({iwd,128'hdddd}),.s_wstrb({iws,16'hffff}),.s_rdata(mrd),
        .m_awaddr(maw),.m_araddr(),.m_awvalid(mav),.m_arvalid(),.m_awap(map),.m_arap(),
        .m_awlen(mal),.m_arlen(),.m_awid(mid),.m_arid(),.m_awready(native_ar),.m_arready(1'b0),
        .m_wready(native_wr),.m_wlast(native_last),.m_rvalid(1'b0),.m_rlast(1'b0),.m_wid(owner_id),
        .m_rid(4'b0),.m_wdata(mwd),.m_wstrb(mws),.m_rdata(128'b0),.fault(mfault));
    always @(posedge core_clk)if(rst_n)begin
        cycles<=cycles+1;
        if(traffic&&!cpu_pending&&!cpu_active&&cycles%997==0)cpu_pending<=1;
        if(traffic&&!video_pending&&!video_active&&cycles%631==0)video_pending<=1;
        if(iar[0])begin cpu_pending<=0;cpu_active<=1;end
        if(mar[0])begin video_pending<=0;video_active<=1;end
        if(iwl[0])begin cpu_active<=0;cpu_count<=cpu_count+1;end
        if(mwl[0])begin video_active<=0;video_count<=video_count+1;end
        if(mav&&native_ar)begin
            sending<=1;owner_id<=mid;beat<=0;
            if(mal!=15)$fatal(1,"burst length changed");
            if(mid==2)begin
                if(maw!=28'h3f80000+tensor_bursts*128)$fatal(1,"tensor address is not contiguous or isolated");
                tensor_bursts<=tensor_bursts+1;
            end
        end
        if(native_wr)begin
            if(mws!=16'hffff)$fatal(1,"write mask changed");
            if(owner_id==2)begin
                if(mwd!==(tensor_beats%2==0 ? 128'h0000000000000000000000aa00550011:128'b0))
                    $fatal(1,"tensor data/padding mismatch beat=%0d data=%h",tensor_beats,mwd);
                tensor_beats<=tensor_beats+1;
            end else if(owner_id==1 && mwd!=128'hcccc)$fatal(1,"CPU write was corrupted");
            else if(owner_id==0 && mwd!=128'hdddd)$fatal(1,"video write was corrupted");
            if(native_last)begin sending<=0;beat<=0;end else beat<=beat+1;
        end
        if(fault||ifault||mfault)$fatal(1,"native bus fault");
    end
    task write_reg;input [7:0] addr;input [31:0] value;begin
        @(negedge clk);wa=addr;wd=value;we=1;
        @(negedge clk);we=0;
    end endtask
    task wait_done;integer wait_cycles;begin
        ra=4;#1;wait_cycles=0;
        while(!rd[1])begin @(negedge clk);wait_cycles=wait_cycles+1;
            if(wait_cycles>2000000)$fatal(1,"CPU completion timeout");end
    end endtask
    task vs_edge;begin
        @(negedge pixel_clk);vs=1;repeat(12)@(negedge pixel_clk);vs=0;
    end endtask
    task begin_raw;input integer value;input integer accepted;begin
        @(negedge core_clk);raw_begin=1;begin_id=value;raw_accepted=1'(accepted);
        @(negedge core_clk);raw_begin=0;
    end endtask
    integer x,y;
    initial begin
        repeat(10)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
        write_reg(8'h10,32'h03fff000);write_reg(0,1);wait_done();
        if(!rd[2]||tensor_beats!=0)$fatal(1,"invalid tensor range accepted");
        write_reg(8'h10,32'h03f00000);write_reg(0,1);
        repeat(120)@(negedge pixel_clk);vs_edge();
        repeat(20)@(negedge pixel_clk);begin_raw(0,1);
        next_id=1;
        for(y=0;y<1080;y=y+1)begin
            for(x=0;x<1920;x=x+1)begin @(negedge pixel_clk);de=1;end
            @(negedge pixel_clk);de=0;repeat(8)@(negedge pixel_clk);
        end
        vs_edge();
        @(negedge core_clk);raw_end=1;end_id=0;
        @(negedge core_clk);raw_end=0;
        wait_done();
        if(rd[2]||!rd[3]||held!=4||tensor_beats!=18432||tensor_bursts!=1152)$fatal(1,"capture publication/count/lease failed");
        ra=8;#1;if(rd!=0)$fatal(1,"wrong published frame ID");
        ra=8'h1c;#1;if(rd!=294912)$fatal(1,"wrong published byte count");
        repeat(200)@(negedge core_clk);if(held!=4)$fatal(1,"frame lease disappeared");
        write_reg(0,1);ra=4;#1;if(!rd[2]||!rd[3])$fatal(1,"start overwrote held descriptor");
        write_reg(0,2);wait_done();if(held!=0||rd[3])$fatal(1,"release failed");
        write_reg(0,1);repeat(120)@(negedge pixel_clk);vs_edge();
        repeat(20)@(negedge pixel_clk);begin_raw(1,0);wait_done();
        if(!rd[2]||rd[3]||held!=0||tensor_beats!=18432)$fatal(1,"dropped raw frame published a tensor");
        write_reg(0,1);repeat(120)@(negedge pixel_clk);vs_edge();
        repeat(20)@(negedge pixel_clk);begin_raw(1,1);next_id=2;
        repeat(12)begin @(negedge pixel_clk);de=1;end
        @(negedge pixel_clk);de=0;repeat(12)@(negedge pixel_clk);vs_edge();wait_done();
        if(!rd[2]||rd[3]||held!=0)$fatal(1,"malformed frame was published");
        if(cpu_count<100||video_count<100)$fatal(1,"concurrent traffic not exercised");
        $display("PASS tensor capture: full RGB888 frame, 18432 checked DDR beats, CPU/video contention, raw identity/lease, invalid range, drop and malformed input cpu=%0d video=%0d",cpu_count,video_count);
        $finish;
    end
    initial begin #40000000;$fatal(1,"test timeout");end
endmodule
