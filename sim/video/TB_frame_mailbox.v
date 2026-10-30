`timescale 1ns/1ps
module TB_frame_mailbox;
    reg clk=0,core_clk=0,rst_n=0,we=0,active=0,ready=1,fault=0;
    always #20 clk=~clk;
    always #3.8 core_clk=~core_clk;
    reg [31:0] wa=0,ra=0,wd=0;
    reg [4:0] available=0;
    reg [159:0] ids=0;
    reg [2:0] wr_slot=0;
    wire [31:0] rd;
    wire [4:0] mask;
    frame_mailbox dut(.clk(clk),.core_clk(core_clk),.rst_n(rst_n),.dev_we(we),.dev_addr_wr(wa),
        .dev_addr_rd(ra),.dev_wdata(wd),.read_data(rd),.available(available),.frame_ids(ids),
        .wr_slot(wr_slot),.wr_active(active),.ddr_ready(ready),.arb_fault(fault),
        .video_shape({16'd1080,16'd1920}),.video_period(32'd416667),.hold_mask(mask));
    task command;input[31:0]value;begin
        @(negedge clk);we=1;wa=32'h30600;wd=value;
        @(negedge clk);we=0;ra=32'h30604;#1;
        while(rd[0])@(negedge clk);
    end endtask
    initial begin
        repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
        command(1);if(!rd[3]||mask!=0)$fatal(1,"empty acquire");
        @(negedge core_clk);available=5'b00110;ids[32+:32]=32'hfffffffe;ids[64+:32]=2;
        wr_slot=2;active=1;
        command(1);if(mask!=2||rd[3])$fatal(1,"acquired active writer slot");
        ids[32+:32]=1234; // returned lease metadata must remain stable.
        ra=32'h3060c;#1;if(rd!=32'hfffffffe)$fatal(1,"unstable lease metadata");
        command(2);if(mask!=0)$fatal(1,"release");
        active=0;ids[32+:32]=32'hfffffffe;
        command(1);if(mask!=4)$fatal(1,"sequence rollover latest selection");
        command(1);if(mask!=4)$fatal(1,"acquire changed existing lease");
        command(2);ready=0;command(1);if(!rd[3]||mask!=0)$fatal(1,"DDR not ready");
        ready=1;fault=1;command(1);if(!rd[3]||mask!=0)$fatal(1,"fault acquire");
        fault=0;available=5'b11111;active=0;
        ids={32'd14,32'd13,32'd12,32'd11,32'd10};
        fork
            command(1);
            begin
                wait(dut.searching);@(negedge core_clk);
                // A PCIe reader may consume the published frames meanwhile.
                available=0;#1;if(mask!=31)$fatal(1,"snapshot reservation lost during scan");
            end
        join
        if(mask!=16||rd[3])$fatal(1,"snapshot/latest selection failed");
        ra=32'h3060c;#1;if(rd!=14)$fatal(1,"reserved frame id changed");
        command(2);
        rst_n=0;repeat(5)@(negedge clk);if(mask!=0)$fatal(1,"reset retained lease");
        $display("PASS frame mailbox: empty/active exclusion, stable metadata, rollover, release, fault/reset");$finish;
    end
    initial begin #100000;$fatal(1,"mailbox timeout");end
endmodule
