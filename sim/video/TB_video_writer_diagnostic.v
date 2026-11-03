`timescale 1ns/1ps
module TB_video_writer_diagnostic;
    reg pixel_clk=0,core_clk=0,clk=0,rst_n=0,en=0;
    always #3 pixel_clk=~pixel_clk;
    always #4 core_clk=~core_clk;
    always #20 clk=~clk;
    reg [15:0] pixel=0;
    wire [383:0] diagnostic;
    wire [4:0] available;
    wire awvalid,wready,wlast,source_fault;
    reg sending=0;
    integer beat=0,cycle=0;
    wire awready=!sending && cycle%4!=0;
    assign wready=sending && cycle%3!=0;
    assign wlast=wready && beat==15;
    ddr3_write_ctrl_lite #(.H_ACTIVE(128),.V_ACTIVE(2)) writer(
        .wr_clk(pixel_clk),.core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(1'b1),
        .fifo_wr_en(en),.fifo_wr_data(pixel),.protect_mask(5'b0),.capture_ok(1'b1),
        .diagnostic(diagnostic),.source_fault(source_fault),.axi_awvalid(awvalid),.axi_awready(awready),
        .axi_wready(wready),.axi_wusero_last(wlast),.frame_done(available),
        .frame_consumed(1'b0),.consumed_frame_id(3'b0));
    always @(posedge core_clk)if(rst_n)begin
        cycle<=cycle+1;
        if(awvalid && awready)begin sending<=1;beat<=0;end
        if(wready)begin
            if(wlast)begin sending<=0;beat<=0;end
            else beat<=beat+1;
        end
    end
    reg we=0;
    reg [7:0] wa=0,ra=8'hc0;
    reg [31:0] wd=0;
    wire [31:0] rd;
    reg [383:0] snapshot;
    video_writer_diagnostic bridge(.clk(clk),.core_clk(core_clk),.rst_n(rst_n),
        .dev_we(we),.addr_wr(wa),.addr_rd(ra),.wdata(wd),.diagnostic(diagnostic),.rdata(rd));
    task take_snapshot;integer i;begin
        @(negedge clk);we=1;wa=8'hc0;wd=1;
        @(negedge clk);we=0;ra=8'hc0;#1;
        while(rd!=2)begin @(negedge clk);#1;end
        for(i=0;i<12;i=i+1)begin
            ra=8'hc4+i*4;#1;snapshot[i*32+:32]=rd;
        end
        if(snapshot[31:0]!=32'h56444731)$fatal(1,"snapshot signature");
    end endtask
    task send_frame;input integer count;integer n;begin
        for(n=0;n<count;n=n+1)begin
            @(negedge pixel_clk);en=1;pixel=n==0 ? 16'h0001:16'h5678;
        end
        @(negedge pixel_clk);en=0;
        repeat(160)@(negedge core_clk);
    end endtask
    reg [383:0] retained;
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        wait(writer.pixel_reset_n && writer.core_reset_n);
        send_frame(256);send_frame(256);send_frame(128);send_frame(256);
        take_snapshot();
        if(snapshot[2*32+:32]!=4 || snapshot[3*32+:32]!=4)$fatal(1,"pixel/core SOF counts");
        if(snapshot[4*32+:32]!=7 || snapshot[5*32+:32]!=1 || snapshot[6*32+:32]!=2)
            $fatal(1,"burst counts or rejected frame snapshot");
        if(snapshot[7*32+:32]!=2 || snapshot[8*32+:32]!=1 || source_fault)
            $fatal(1,"publication/rejection count");
        retained=snapshot;
        send_frame(256);
        // A live writer cannot tear a previously latched CPU snapshot.
        ra=8'hd4;#1;if(rd!=retained[4*32+:32])$fatal(1,"snapshot changed without request");
        take_snapshot();
        if(snapshot[4*32+:32]!=9 || snapshot[7*32+:32]!=3 || snapshot[8*32+:32]!=1)
            $fatal(1,"snapshot refresh or writer behavior changed");
        rst_n=0;repeat(3)@(negedge clk);ra=8'hc0;#1;
        if(rd!=0)$fatal(1,"reset did not invalidate snapshot");
        $display("PASS writer diagnostic: coherent CDC snapshot, SOF/burst counts, short-frame rejection, publication, reset");
        $finish;
    end
    initial begin #100000;$fatal(1,"writer diagnostic timeout");end
endmodule
