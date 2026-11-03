`timescale 1ns/1ps
// Native command path with actual vendor controller/PHY and DDR device model.
module TB_vendor_ddr_retention;
    reg clk=0,rst_n=1,grs_n=0;
    always #20 clk=~clk;
    initial begin #5;grs_n=1;#5;rst_n=0;#1000;rst_n=1;end
    GTP_GRS GRS_INST(.GRS_N(grs_n));
    wire core_clk,ready;
    reg cmd_valid=0,cmd_write=0,wr_valid=0;
    reg [31:0] cmd_addr=0,cmd_len=16;
    reg [127:0] wr_data=0;
    reg [15:0] write_mask=16'hffff;
    wire cmd_ready,wr_ready,rd_valid,done,error,fault;
    wire [127:0] rd_data;
    wire [3:0] error_code;
    wire [27:0] axi_awaddr,axi_araddr;
    wire axi_awuser_ap,axi_aruser_ap,axi_awvalid,axi_arvalid,axi_awready,axi_arready;
    wire [3:0] axi_awuser_id,axi_aruser_id,axi_awlen,axi_arlen,axi_wusero_id,axi_rid;
    wire axi_wready,axi_wusero_last,axi_rlast,axi_rvalid;
    wire [127:0] axi_wdata,axi_rdata;
    wire [15:0] transfer_wstrb;
    wire [15:0] axi_wstrb=transfer_wstrb&write_mask;
    wire mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_cs_n,mem_ras_n,mem_cas_n,mem_we_n,mem_odt;
    wire [14:0] mem_a;
    wire [2:0] mem_ba;
    wire [15:0] mem_dq;
    wire [1:0] mem_dqs,mem_dqs_n,mem_dm;
    ddr_block_transfer transfer(
        .core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(ready),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_len(cmd_len),
        .clear_status(1'b0),.done(done),.error(error),.fault(fault),.error_code(error_code),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),
        .rd_valid(rd_valid),.rd_ready(1'b1),.rd_data(rd_data),
        .axi_awaddr(axi_awaddr),.axi_araddr(axi_araddr),.axi_awuser_ap(axi_awuser_ap),.axi_aruser_ap(axi_aruser_ap),
        .axi_awuser_id(axi_awuser_id),.axi_aruser_id(axi_aruser_id),.axi_awlen(axi_awlen),.axi_arlen(axi_arlen),
        .axi_awvalid(axi_awvalid),.axi_arvalid(axi_arvalid),.axi_awready(axi_awready),.axi_arready(axi_arready),
        .axi_wdata(axi_wdata),.axi_wstrb(transfer_wstrb),.axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),
        .axi_rdata(axi_rdata),.axi_rid(axi_rid),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid));
    `include "vendor_ddr_instance.vh"
`ifndef VENDOR_CONTROLLER_ONLY
    // Match the reference bench's first CA group delay. Device timing checks stay enabled.
    wire #0.15 device_rst_n=mem_rst_n,device_ck=mem_ck,device_ck_n=mem_ck_n;
    wire #0.15 device_cke=mem_cke,device_ras_n=mem_ras_n,device_cas_n=mem_cas_n;
    wire #0.15 device_we_n=mem_we_n,device_odt=mem_odt;
    wire [14:0] #0.15 device_a=mem_a;
    wire [2:0] #0.15 device_ba=mem_ba;
    ddr3_device_model memory(
        .rst_n(device_rst_n),.ck(device_ck),.ck_n(device_ck_n),.cke(device_cke),.cs_n(1'b0),
        .ras_n(device_ras_n),.cas_n(device_cas_n),.we_n(device_we_n),.addr(device_a),.ba(device_ba),
        .odt(device_odt),.dq(mem_dq),.dqs(mem_dqs),.dqs_n(mem_dqs_n),.dm_tdqs(mem_dm),.tdqs_n());
`endif
    reg [127:0] tx[0:15],rx[0:15];
    integer read_index=0;
    always @(posedge core_clk)begin
        if(rd_valid)begin rx[read_index]=rd_data;read_index=read_index+1;end
        if(rst_n&&error)$fatal(1,"native transfer error=%d",error_code);
    end
    task execute(input integer writing,input [31:0] address,input integer bytes);
        integer i;begin
            @(negedge core_clk);while(!cmd_ready)@(negedge core_clk);
            read_index=0;cmd_write=writing;cmd_addr=address;cmd_len=bytes;cmd_valid=1;
            @(negedge core_clk);cmd_valid=0;
            if(writing)begin
                for(i=0;i<bytes/16;i=i+1)begin
                    wr_valid=1;wr_data=tx[i];
                    while(!wr_ready)@(negedge core_clk);
                    @(negedge core_clk);
                end
                wr_valid=0;
            end
            while(!done&&!error)@(negedge core_clk);
            if(error)$fatal(1,"transfer failed");
            $display("VENDOR transaction write=%0d address=%h bytes=%0d mask=%h",writing,address,bytes,write_mask);
        end
    endtask
    `include "vendor_ddr_fixture.vh"
`ifndef VENDOR_CONTROLLER_ONLY
    // Testbench-only progress; do not alter clocks, training, or timing checks.
    initial forever begin
        #10000;
        $display("VENDOR PROGRESS t=%0t ready=%b pll=%b phy_pll=%b reset_state=%h calib=%h slice=%h init_fail=%b",
                 $time,ready,dut.pll_lock,dut.phy_pll_lock,dut.debug_rst_state,
                 dut.debug_calib_ctrl,dut.dbg_slice_state,dut.dbg_ddrphy_init_fail);
    end
`endif
    initial begin #2000000;$fatal(1,"vendor DDR timeout ready=%b",ready);end
endmodule
