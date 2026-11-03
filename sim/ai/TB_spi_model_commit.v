`timescale 1ns/1ps
// Real SPI pins + unmodified production firmware + CPU + shared DDR arbiters.
// Fixture preloads two headers and fast-forwards the already-uploaded prefix.
// The final CHUNK and COMMIT execute entirely through the normal firmware path.
module TB_spi_model_commit #(parameter ENABLE_DUAL=1);
    reg clk=0,rst_n=0,sck=1,cs=1,drive=0;
    reg [3:0] dq=0;
    wire [3:0] bus;
    assign bus=drive?dq:4'bzzzz;
    always #20 clk=~clk;
    wire core_clk,ready,bus_err,shared_fault;
    wire [27:0] axi_awaddr,axi_araddr;
    wire axi_awuser_ap,axi_aruser_ap,axi_awvalid,axi_arvalid,axi_awready,axi_arready;
    wire [3:0] axi_awuser_id,axi_aruser_id,axi_awlen,axi_arlen,axi_wusero_id,axi_rid;
    wire axi_wready,axi_wusero_last,axi_rlast,axi_rvalid;
    wire [127:0] axi_wdata,axi_rdata;
    wire [15:0] axi_wstrb;
    wire [8:0] tensor_rd;
    wire [31:0] tensor_rdata=tensor_rd[8] ? 32'h18 :
        (tensor_rd==9'h038 ? 32'h53494d31 : tensor_rd==4 ? 32'h10 : 32'h0);
    soc #(.ENABLE_DUAL(ENABLE_DUAL),.ENABLE_FSPI(1),.ENABLE_DDR(1),.ENABLE_AI(1),
          .AI_ACT_WIDTH(16),.ENABLE_FRAME_CONTROL(1),.ENABLE_PREPROCESS(1),.DDR_LIMIT_BYTES(32'h04000000)) cpu(
        .clk(clk),.rst_n(rst_n),.spi_clk(sck),.spi_cs(cs),.spi_data(bus),.timer_irq(1'b0),
        .core_clk(core_clk),.ddr_init_done(ready),.shared_ddr_fault(shared_fault),
        .frame_available(5'b0),.frame_ids(160'b0),.frame_wr_slot(3'b0),.frame_wr_active(1'b0),
        .video_shape(32'b0),.video_period(32'b0),.pixclk_in(1'b0),.vs_in(1'b0),.hs_in(1'b0),.de_in(1'b0),
        .r_in(8'b0),.g_in(8'b0),.b_in(8'b0),.tensor_addr_rd(tensor_rd),.tensor_rdata(tensor_rdata),
        .axi_awaddr(axi_awaddr),.axi_araddr(axi_araddr),.axi_awuser_ap(axi_awuser_ap),.axi_aruser_ap(axi_aruser_ap),
        .axi_awvalid(axi_awvalid),.axi_arvalid(axi_arvalid),.axi_awready(axi_awready),.axi_arready(axi_arready),
        .axi_awuser_id(axi_awuser_id),.axi_aruser_id(axi_aruser_id),.axi_awlen(axi_awlen),.axi_arlen(axi_arlen),
        .axi_wready(axi_wready),.axi_wusero_last(axi_wusero_last),.axi_wusero_id(axi_wusero_id),
        .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),
        .axi_rlast(axi_rlast),.axi_rid(axi_rid),.bus_err(bus_err));
    frame_ring_ddr3 #(.SPI_IMAGE(1),.ENABLE_PCIE_READER(0)) ring(
        .sys_clk(clk),.sys_rst_n(rst_n),.clr(1'b0),.core_clk(core_clk),.ddr_init_done(ready),
        .cpu_awaddr(axi_awaddr),.cpu_araddr(axi_araddr),.cpu_awvalid(axi_awvalid),.cpu_arvalid(axi_arvalid),
        .cpu_awap(axi_awuser_ap),.cpu_arap(axi_aruser_ap),.cpu_awlen(axi_awlen),.cpu_arlen(axi_arlen),
        .cpu_awid(axi_awuser_id),.cpu_arid(axi_aruser_id),.cpu_wdata(axi_wdata),.cpu_wstrb(axi_wstrb),
        .cpu_awready(axi_awready),.cpu_arready(axi_arready),.cpu_wready(axi_wready),.cpu_wlast(axi_wusero_last),
        .cpu_wid(axi_wusero_id),.cpu_rdata(axi_rdata),.cpu_rvalid(axi_rvalid),.cpu_rlast(axi_rlast),.cpu_rid(axi_rid),
        .tensor_awaddr(28'b0),.tensor_awvalid(1'b0),.tensor_awap(1'b0),.tensor_awlen(4'b0),.tensor_awid(4'b0),
        .tensor_wdata(128'b0),.tensor_wstrb(16'b0),.tensor_hold(5'b0),.tensor_fault(1'b0),
        .image_active(1'b0),.image_held(1'b0),.image_available(1'b0),.image_fault(1'b0),.image_id(32'b0),
        .image_awaddr(28'b0),.image_araddr(28'b0),.image_awvalid(1'b0),.image_arvalid(1'b0),
        .image_awap(1'b0),.image_arap(1'b0),.image_awlen(4'b0),.image_arlen(4'b0),.image_arid(4'b0),
        .image_wdata(128'b0),.image_wstrb(16'b0),
        .hold_mask(5'b0),.present_hold(5'b0),.present_frames(5'b0),.present_box_count(5'b0),.present_boxes(1024'b0),
        .stream_ok(1'b1),.wr_clk(clk),.wr_data(16'b0),.wr_en(1'b0),.vs(1'b0),.de(1'b0),
        .rd_clk(clk),.dma_start(1'b0),.rd_en(1'b0),.shared_fault(shared_fault));
    reg [7:0] request[0:255],reply[0:255];
    integer ar_count=0,aw_count=0,frames=0;
    reg [27:0] reads[0:7];
    always @(posedge core_clk)if(rst_n)begin
        if(shared_fault)$fatal(1,"DDR shared fault");
        if(ring.m_awvalid&&ring.m_awready)begin
            aw_count=aw_count+1;$display("NATIVE WRITE addr=%h len=%0d",ring.m_awaddr,ring.m_awlen+1);
        end
        if(ring.m_arvalid&&ring.m_arready)begin
            if(ar_count>=8)$fatal(1,"unexpected read count");
            reads[ar_count]=ring.m_araddr;ar_count=ar_count+1;
            $display("NATIVE READ addr=%h len=%0d",ring.m_araddr,ring.m_arlen+1);
        end
    end
    always @(posedge clk)if(rst_n)begin
        if(bus_err)$fatal(1,"CPU bus error pc=%h address=%h write=%b read=%b",cpu.u_core.pc,cpu.dev_addr_rd,cpu.dev_we,cpu.dev_re);
        if(cpu.dev_we&&cpu.dev_addr_wr==32'h31000)
            $display("WINDOW control=%h address=%h length=%0d",cpu.dev_wdata,
                cpu.u_peripheral_bus.g_ddr.u_window.address_reg,cpu.u_peripheral_bus.g_ddr.u_window.length_reg);
    end
    task put32(input integer at,input [31:0] value);begin
        request[at]=value[7:0];request[at+1]=value[15:8];request[at+2]=value[23:16];request[at+3]=value[31:24];
    end endtask
    function [31:0] get32(input integer at);get32={reply[at+3],reply[at+2],reply[at+1],reply[at]};endfunction
    task nibble(input [3:0] value);begin sck=0;drive=1;dq=value;#10;sck=1;#10;end endtask
    task send(input [7:0] value);begin nibble(value[7:4]);nibble(value[3:0]);end endtask
    task recv(output [7:0] value);begin
        drive=0;sck=0;#10;sck=1;#1;value[7:4]=bus;#9;
        sck=0;#10;sck=1;#1;value[3:0]=bus;#9;
    end endtask
    task receive_frame;
        integer j,size;reg [31:0] crc;
        begin
            wait(cpu.u_peripheral_bus.g_fspi.u_fspi.tx_pending);
            #1100;cs=0;#7;send(8'h80);
            for(j=0;j<256;j=j+1)recv(reply[j]);
            #3;cs=1;drive=0;#1100;
            if(get32(0)!==32'h31545053)$fatal(1,"SPI response magic");
            size=16+{reply[11],reply[10]};if(size>256)$fatal(1,"response size");
            crc=2166136261;
            for(j=0;j<size;j=j+1)if(j<12||j>=16)crc=(crc^reply[j])*32'd16777619;
            if(crc!==get32(12))$fatal(1,"response checksum");
            frames=frames+1;
        end
    endtask
    task exchange(input [15:0] op,input [31:0] seq,input integer payload);
        integer j,attempt;reg [31:0] crc;reg found;
        begin
            put32(0,32'h31545053);put32(4,seq);
            request[8]=op[7:0];request[9]=op[15:8];request[10]=payload;request[11]=0;
            crc=2166136261;
            for(j=0;j<16+payload;j=j+1)if(j<12||j>=16)crc=(crc^request[j])*32'd16777619;
            put32(12,crc);
            wait(cpu.u_peripheral_bus.g_fspi.u_fspi.rx_armed);
            #1100;cs=0;#7;send(0);
            for(j=0;j<256;j=j+1)send(request[j]);
            #3;cs=1;drive=0;#1100;found=0;attempt=0;
            while(!found&&attempt<16)begin
                receive_frame;attempt=attempt+1;
                found=({reply[9],reply[8]}==16'h8003&&get32(4)==seq);
            end
            if(!found||get32(20)!==op)$fatal(1,"missing response op=%0d",op);
            $display("SPI op=%0d status=%0d network_state=%0d received=%0d",op,get32(16),get32(28),get32(44));
        end
    endtask
    task poke32(input [31:0] address,input [31:0] value);
        integer lane;begin
            for(lane=0;lane<4;lane=lane+1)
                cpu.u_core.u_memory.u_memory_core.memory[(address&65535)+lane]=value[lane*8+:8];
        end
    endtask
    `include "model_commit_fixture.vh"
    initial begin
        #3000000;
        $display("FSPI armed=%b ready=%b txpending=%b active=%b rejected=%b fault=%b idx=%d req=%b done=%b rxlength=%d count=%d",
            cpu.u_peripheral_bus.g_fspi.u_fspi.rx_armed,cpu.u_peripheral_bus.g_fspi.u_fspi.rx_ready,
            cpu.u_peripheral_bus.g_fspi.u_fspi.tx_pending,cpu.u_peripheral_bus.g_fspi.u_fspi.active,
            cpu.u_peripheral_bus.g_fspi.u_fspi.cpu_rejected,cpu.u_peripheral_bus.g_fspi.u_fspi.protocol_error,
            cpu.u_peripheral_bus.g_fspi.u_fspi.cpu_index,cpu.u_peripheral_bus.g_fspi.u_fspi.rx_req,
            cpu.u_peripheral_bus.g_fspi.u_fspi.rx_done_sync,cpu.u_peripheral_bus.g_fspi.u_fspi.rx_length,
            cpu.u_peripheral_bus.g_fspi.u_fspi.last_count);
        $fatal(1,"SPI model commit timeout pc=%h frames=%0d",cpu.u_core.pc,frames);
    end
endmodule
