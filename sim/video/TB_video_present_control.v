`timescale 1ns/1ps
module TB_video_present_control;
    reg clk=0,core_clk=0,pcie_clk=0,rst_n=0,pcie_rst_n=1,pcie_link_up=0,ddr_ready=1;
    always #20 clk=~clk;always #4 core_clk=~core_clk;always #5 pcie_clk=~pcie_clk;
    reg dev_we=0;reg [7:0] addr_wr=0,addr_rd=4;reg [31:0] wdata=0;
    wire [31:0] rdata;
    reg [4:0] frame_available=4,frame_held=4;
    reg [159:0] frame_ids=0;reg [2:0] write_slot=0;
    reg write_active=0,reader_busy=0,reader_done=0,pixel_valid=0,pixel_ready=0,dma_busy=0,stream_empty=1;
    wire [4:0] reader_frames,protect_mask,active_count;wire [1023:0] active_boxes;
    video_present_control #(.WIDTH(32),.HEIGHT(8)) dut(.*);
    task wr(input [7:0] a,input [31:0] d);
        begin @(negedge clk);dev_we=1;addr_wr=a;wdata=d;@(negedge clk);dev_we=0;end
    endtask
    task config_job(input [31:0] id);
        begin wr(8,id);wr(12,2);wr(16,0);end
    endtask
    task reset_all;
        begin rst_n=0;reader_busy=0;reader_done=0;pixel_ready=0;pixel_valid=0;dma_busy=0;stream_empty=1;
        repeat(4)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);end
    endtask
    integer i;
    initial begin
        frame_ids[64+:32]=42;reset_all();
        config_job(42);wr(0,1);repeat(4)@(negedge clk);
        if(rdata[2:0]!=6 || reader_frames || protect_mask)$fatal(1,"no-link request not rejected");
        pcie_link_up=1;repeat(8)@(negedge clk);
        config_job(43);wr(0,1);wait(rdata[1]);
        if(!rdata[2] || protect_mask)$fatal(1,"mismatched frame not rejected");
        config_job(42);wr(0,1);wait(reader_frames==4);
        if(protect_mask!=4)$fatal(1,"missing frame lease");
        repeat(4)@(negedge clk);
        if(!rdata[0] || rdata[6] || rdata[5])$fatal(1,"busy alone must not grant DMA before reader start");
        @(negedge core_clk);reader_busy=1;repeat(4)@(negedge core_clk);reader_done=1;
        @(negedge core_clk);reader_done=0;reader_busy=0;
        repeat(8)@(negedge clk);
        if((rdata&32'h65)!=32'h41 || protect_mask!=4)$fatal(1,"normal DMA readiness must be busy+prepared, never locked: %h",rdata);
        @(negedge pcie_clk);dma_busy=1;stream_empty=0;pixel_valid=1;
        for(i=0;i<32;i=i+1)begin pixel_ready=1;@(negedge pcie_clk);pixel_ready=0;@(negedge pcie_clk);end
        pixel_valid=0;repeat(6)@(negedge clk);
        if(!rdata[0] || protect_mask!=4)$fatal(1,"released before DMA/pipe drained");
        dma_busy=0;stream_empty=1;wait(rdata[1]);
        if(rdata[2] || protect_mask)$fatal(1,"completion failed");
        repeat(4)@(negedge clk);
        if(rdata[6] || rdata[5] || rdata[0])$fatal(1,"DMA permission not cleared after completion");
        reset_all();config_job(42);wr(0,1);wait(reader_frames==4);
        @(negedge core_clk);reader_busy=1;
        @(negedge pcie_clk);pixel_ready=1;pixel_valid=0;
        wait(rdata[5] && rdata[1]);
        if(!rdata[2] || protect_mask!=4)$fatal(1,"underflow must lock frame until reset");
        repeat(4)@(negedge clk);
        if(rdata[6])$fatal(1,"fault lock must revoke DMA permission");
        reset_all();config_job(42);wr(0,1);wait(reader_frames==4);
        pcie_link_up=0;wait(rdata[5] && rdata[1]);
        if(!rdata[2] || protect_mask!=4)$fatal(1,"link loss must lock frame until reset");
        repeat(4)@(negedge clk);
        if(rdata[6])$fatal(1,"link loss must revoke DMA permission");
        $display("PASS presentation: busy-before-ready, prepared bit 6 vs fault bit 5, frame identity, DMA drain and fault leases");$finish;
    end
    initial begin #100000;$fatal(1,"presentation timeout status=%h",rdata);end
endmodule
