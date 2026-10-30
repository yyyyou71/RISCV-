`timescale 1ns/1ps
module TB_standalone_capture;
    reg clk=0,pixel_clk=0,key_n=0;
    always #20 clk=~clk;
    always #3.367 pixel_clk=~pixel_clk;
    wire led0,led1;
    tri1 iic_sda,hd_sda;
    acore_dual_top #(.STANDALONE_CAPTURE(1),.RESET_HOLD_CYCLES(8)) dut(
        .sys_clk(clk),.key0_n(key_n),.iic_scl(1'b1),.iic_sda(iic_sda),.led0(led0),.led1(led1),
        .ref_clk_p(1'b0),.ref_clk_n(1'b0),.perst_n(1'b0),.rxn(2'b0),.rxp(2'b0),.txn(),.txp(),
        .pixclk_in(pixel_clk),.vs_in(1'b0),.hs_in(1'b0),.de_in(1'b0),
        .r_in(8'b0),.g_in(8'b0),.b_in(8'b0),.hd_scl(),.hd_sda(hd_sda),
        .mem_rst_n(),.mem_ck(),.mem_ck_n(),.mem_cke(),.mem_cs_n(),.mem_ras_n(),
        .mem_cas_n(),.mem_we_n(),.mem_odt(),.mem_a(),.mem_ba(),.mem_dqs(),.mem_dqs_n(),.mem_dq(),.mem_dm());
    wire full_mode_reset;
    acore_video_platform #(.STANDALONE_CAPTURE(0),.RESET_HOLD_CYCLES(8)) full_mode(
        .monitor_clk(clk),.sys_clk(clk),.button_rst_n(key_n),
        .tensor_we(1'b0),.tensor_addr_wr(8'b0),.tensor_addr_rd(8'b0),.tensor_wdata(32'b0),.tensor_rdata(),
        .ref_clk_p(1'b0),.ref_clk_n(1'b0),.perst_n(1'b0),.rxn(2'b0),.rxp(2'b0),
        .pixclk_in(pixel_clk),.vs_in(1'b0),.hs_in(1'b0),.de_in(1'b0),.r_in(8'b0),.g_in(8'b0),.b_in(8'b0),
        .cpu_awaddr(28'b0),.cpu_araddr(28'b0),.cpu_awvalid(1'b0),.cpu_arvalid(1'b0),
        .cpu_awap(1'b0),.cpu_arap(1'b0),.cpu_awlen(4'b0),.cpu_arlen(4'b0),
        .cpu_awid(4'b0),.cpu_arid(4'b0),.cpu_wdata(128'b0),.cpu_wstrb(16'b0),
        .frame_hold_mask(5'b0),.system_rst_n(full_mode_reset));
    integer reads=0;
    always @(posedge clk)if(dut.u_board.u_soc.dev_re&&dut.u_board.u_soc.dev_addr_rd==32'h3061c)reads<=reads+1;
    task check_live;begin
        repeat(5000)@(negedge clk);
        if(dut.u_video.core_rst_n!==0||dut.u_video.pclk!==0||dut.u_video.ref_clk!==0)
            $fatal(1,"PCIe model did not remain clockless/in reset");
        if(dut.system_rst_n!==1||dut.u_board.rst_n!==1||dut.ready!==1)
            $fatal(1,"local CPU/DDR still depend on PCIe reset");
        if(reads<5)$fatal(1,"real CPU did not execute the selected bringup image");
        if(full_mode_reset!==0)$fatal(1,"full PCIe mode no longer follows original reset");
        if(dut.u_video.u_hdmi_fifo.r_arvalid!==0||dut.u_video.u_hdmi_fifo.reader_hold!==0||
           dut.u_video.fifo_rd_empty!==1)$fatal(1,"standalone mode started a PCIe video read");
        if(dut.fault!==0)$fatal(1,"clockless PCIe caused a local DDR fault");
    end endtask
    initial begin
        repeat(4)@(negedge clk);key_n=1;
        check_live();
        // Even a valid raw frame must not make the disabled PCIe reader start.
        force dut.u_video.u_hdmi_fifo.frame_done=5'b00001;
        repeat(100)@(negedge clk);
        if(dut.u_video.u_hdmi_fifo.r_arvalid!==0||dut.u_video.u_hdmi_fifo.reader_hold!==0)
            $fatal(1,"available frame caused a standalone PCIe read/lease");
        release dut.u_video.u_hdmi_fifo.frame_done;
        // Accelerate only the software cycle counter to enter the no-HDMI
        // error path; there is no seconds-long simulation or image stream.
        force dut.u_board.u_soc.u_peripheral_bus.cycle_count=32'd100000000;
        repeat(200)@(negedge clk);
        if(dut.u_board.gpio_out!==3||led0===dut.ready_sync[1])$fatal(1,"error code first pulse missing");
        force dut.fault_sync=2'b11;
        force dut.u_board.u_soc.u_peripheral_bus.cycle_count=32'd104000000;
        repeat(200)@(negedge clk);
        if(dut.u_board.gpio_out!==2||led0!==dut.ready_sync[1]||led1!==1)
            $fatal(1,"hardware fault masked LED0 diagnostic");
        force dut.u_board.u_soc.u_peripheral_bus.cycle_count=32'd108000000;
        repeat(200)@(negedge clk);
        if(dut.u_board.gpio_out!==3)$fatal(1,"error code second pulse missing");
        force dut.u_board.u_soc.u_peripheral_bus.cycle_count=32'd112000000;
        repeat(200)@(negedge clk);
        if(dut.u_board.gpio_out!==2)$fatal(1,"error code second pulse did not end");
        force dut.u_board.u_soc.u_peripheral_bus.cycle_count=32'd116000000;
        repeat(200)@(negedge clk);
        if(dut.u_board.gpio_out!==2)$fatal(1,"error code missing group gap");
        release dut.fault_sync;
        release dut.u_board.u_soc.u_peripheral_bus.cycle_count;
        key_n=0;repeat(4)@(negedge clk);
        if(dut.system_rst_n!==0||dut.u_board.rst_n!==0)$fatal(1,"local key reset did not assert");
        reads=0;key_n=1;check_live();
        $display("PASS standalone capture: PCIe clocks=0/PERST=0, local DDR/real CPU startup, disabled reader, LED error code with hard fault, key reset/restart, full-mode reset preserved");
        $finish;
    end
    initial begin #1000000;$fatal(1,"standalone reset timeout");end
endmodule
