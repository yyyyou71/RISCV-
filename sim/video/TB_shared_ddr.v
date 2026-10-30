`timescale 1ns/1ps
module TB_shared_ddr;
    reg clk=0,ref_clk=0,rst_n=0;
    always #20 clk=~clk;
    always #20 ref_clk=~ref_clk;
    wire core_clk,ready;
    wire [27:0] ca,cr,ma,mr;
    wire cav,crv,cap,crp,car,crr,cwr,cwl,crvalid,crlast;
    wire [3:0] cal,crl,ci,cri,cwi,crid;
    wire [127:0] cwd,crd,mwd,mrd;
    wire [15:0] cws,mws;
    wire [1:0] sr_aw,sr_ar,sr_w,sr_wlast,sr_rvalid,sr_rlast;
    wire [7:0] sr_wid,sr_rid;
    wire [255:0] sr_data;
    wire mav,mrv,map,mrp,mar,mrr,mwr,mwl,mrvalid,mrlast;
    wire [3:0] mal,mrl,mi,mri,mwi,mrid;
    wire fault,buserr;
    wire [1:0] gpio;
    wire [4:0] hold_mask;
    reg [159:0] ids=0;
    reg [2:0] vs=0;
    integer round=0,beat=0,video_reads=0,video_writes=0,leases=0,releases=0;
    reg old_hold=0;
    wire [27:0] va=round*128;
    wire [127:0] vd={4{32'h12340000+32'(round*16+beat)}};
    soc #(.ENABLE_DUAL(1),.ENABLE_DDR(1),.ENABLE_FRAME_CONTROL(1),.DDR_LIMIT_BYTES(32'h04000000)) cpu (
        .clk(clk),.rst_n(rst_n),.timer_irq(1'b0),.core_clk(core_clk),.ddr_init_done(ready),
        .pixclk_in(1'b0),.vs_in(1'b0),.hs_in(1'b0),.de_in(1'b0),.r_in(8'd0),.g_in(8'd0),.b_in(8'd0),
        .frame_available(5'b01100),.frame_ids(ids),.frame_wr_slot(3'd4),.frame_wr_active(1'b1),
        .shared_ddr_fault(fault),.video_shape({16'd1080,16'd1920}),.video_period(32'd416667),.frame_hold_mask(hold_mask),
        .rk_tx_data(),.rk_tx_valid(),.rk_tx_ready(1'b1),.rk_param_data(32'd0),.rk_param_update(1'b0),
        .uart_txd(),.gpio_out(gpio),.bus_err(buserr),
        .axi_awaddr(ca),.axi_araddr(cr),.axi_awvalid(cav),.axi_arvalid(crv),.axi_awuser_ap(cap),.axi_aruser_ap(crp),
        .axi_awlen(cal),.axi_arlen(crl),.axi_awuser_id(ci),.axi_aruser_id(cri),.axi_awready(car),.axi_arready(crr),
        .axi_wdata(cwd),.axi_wstrb(cws),.axi_wready(cwr),.axi_wusero_last(cwl),.axi_wusero_id(cwi),
        .axi_rdata(crd),.axi_rid(crid),.axi_rvalid(crvalid),.axi_rlast(crlast));
    ddr_native_arbiter arb(.clk(core_clk),.rst_n(rst_n),
        .s_awaddr({ca+28'h2000000,va}),.s_araddr({cr+28'h2000000,va}),
        .s_awvalid({cav,vs==0&&round<32}),.s_arvalid({crv,vs==2}),
        .s_awap({cap,1'b0}),.s_arap({crp,1'b0}),.s_awlen({cal,4'd15}),.s_arlen({crl,4'd15}),
        .s_awid({ci,4'd9}),.s_arid({cri,4'd9}),.s_awready(sr_aw),.s_arready(sr_ar),
        .s_wready(sr_w),.s_wlast(sr_wlast),.s_rvalid(sr_rvalid),.s_rlast(sr_rlast),
        .s_wid(sr_wid),.s_rid(sr_rid),.s_wdata({cwd,vd}),.s_wstrb({cws,16'hffff}),.s_rdata(sr_data),
        .m_awaddr(ma),.m_araddr(mr),.m_awvalid(mav),.m_arvalid(mrv),.m_awap(map),.m_arap(mrp),
        .m_awlen(mal),.m_arlen(mrl),.m_awid(mi),.m_arid(mri),.m_awready(mar),.m_arready(mrr),
        .m_wdata(mwd),.m_wstrb(mws),.m_wready(mwr),.m_wlast(mwl),.m_wid(mwi),
        .m_rdata(mrd),.m_rid(mrid),.m_rvalid(mrvalid),.m_rlast(mrlast),.fault(fault));
    assign car=sr_aw[1];assign crr=sr_ar[1];assign cwr=sr_w[1];assign cwl=sr_wlast[1];
    assign cwi=sr_wid[7:4];assign crvalid=sr_rvalid[1];assign crlast=sr_rlast[1];
    assign crid=sr_rid[7:4];assign crd=sr_data[255:128];
    ddr3 memory(.ref_clk(ref_clk),.resetn(rst_n),.core_clk(core_clk),.ddr_init_done(ready),
        .axi_awaddr(ma),.axi_awvalid(mav),.axi_awuser_ap(map),.axi_awlen(mal),.axi_awuser_id(mi),.axi_awready(mar),
        .axi_wdata(mwd),.axi_wstrb(mws),.axi_wready(mwr),.axi_wusero_last(mwl),.axi_wusero_id(mwi),
        .axi_araddr(mr),.axi_arvalid(mrv),.axi_aruser_ap(mrp),.axi_arlen(mrl),.axi_aruser_id(mri),.axi_arready(mrr),
        .axi_rdata(mrd),.axi_rid(mrid),.axi_rvalid(mrvalid),.axi_rlast(mrlast),
        .apb_clk(clk),.apb_rst_n(rst_n),.apb_sel(1'b0),.apb_enable(1'b0),.apb_write(1'b0),.apb_addr(8'd0),.apb_wdata(16'd0),
        .dbg_gate_start(1'b0),.dbg_cpd_start(1'b0),.dbg_ddrphy_rst_n(1'b1),.dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0),.wrcal_position_dyn_adj(1'b0),.init_samp_position_even(16'd0),
        .init_samp_position_odd(16'd0),.init_wrcal_position(16'd0),.init_slip_step(8'd0),
        .init_read_clk_ctrl(6'd0),.force_read_clk_ctrl(1'b0),.debug_cpd_offset_adj(1'b0),
        .debug_cpd_offset_dir(1'b0),.debug_cpd_offset(10'd0),.ck_dly_en(1'b0),.init_ck_dly_step(8'd0));
    always @(posedge core_clk)if(rst_n&&ready)begin
        if(fault||buserr||gpio[1])$fatal(1,"shared DDR/CPU failure");
        if((sr_w==3)||(sr_rvalid==3))$fatal(1,"response delivered to two owners");
        if(cav && ca>=28'h2000000 || crv && cr>=28'h2000000)$fatal(1,"CPU region check failed");
        case(vs)
            0:if(sr_aw[0])begin vs<=1;beat<=0;end
            1:if(sr_w[0])begin
                if(sr_wid[3:0]!=9||sr_wlast[0]!=(beat==15))$fatal(1,"video write owner/length");
                video_writes<=video_writes+1;
                if(beat==15)begin vs<=2;beat<=0;end else beat<=beat+1;
            end
            2:if(sr_ar[0])begin vs<=3;beat<=0;end
            3:if(sr_rvalid[0])begin
                if(sr_rid[3:0]!=9||sr_data[127:0]!==vd||sr_rlast[0]!=(beat==15))$fatal(1,"video read corruption");
                video_reads<=video_reads+1;
                if(beat==15)begin vs<=0;round<=round+1;beat<=0;end else beat<=beat+1;
            end
        endcase
        if(cpu.u_peripheral_bus.g_frames.u_frames.core_held&&!old_hold)begin
            if(hold_mask!=5'b01000)$fatal(1,"lease did not select latest frame");
            leases<=leases+1;
        end
        if(!cpu.u_peripheral_bus.g_frames.u_frames.core_held&&old_hold)releases<=releases+1;
        old_hold<=cpu.u_peripheral_bus.g_frames.u_frames.core_held;
        if(gpio==1 && round==32 && leases>=2 && releases>=2)begin
            $display("PASS shared DDR: video_writes=%0d video_reads=%0d leases=%0d releases=%0d CPU_bounds=1",video_writes,video_reads,leases,releases);
            $finish;
        end
    end
    initial begin ids[2*32+:32]=42;ids[3*32+:32]=43;repeat(8)@(negedge clk);rst_n=1;end
    initial begin #100000000;$fatal(1,"shared DDR timeout");end
endmodule
