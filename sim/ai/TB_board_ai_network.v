`timescale 1ns/1ps
// Actual board hierarchy/dual Acore/shared arbiters/range checks/AI RTL.
// External HDMI/PCIe are idle: this case starts from a DDR-resident tensor.
module TB_board_ai_network #(
    parameter integer PREPROCESS=0
);
    GTP_GRS GRS_INST(.GRS_N(1'b1));
    reg clk=0,pixel_clk=0,key_n=0;
    always #20 clk=~clk;
    always #3.367 pixel_clk=~pixel_clk;
    wire core_clk=dut.core_clk;
    wire rst_n=dut.u_board.rst_n;
    tri1 hd_sda;
    tri [3:0] spi_data;
    reg vs=0,hs=0,de=0;
    reg [23:0] rgb=0;
    acore_dual_top #(.ENABLE_AI(1),.ENABLE_FSPI(0),.STANDALONE_CAPTURE(1),.RESET_HOLD_CYCLES(8)) dut(
        .sys_clk(clk),.key0_n(key_n),.spi_clk(1'b0),.spi_cs(1'b1),.spi_data(spi_data),
        .ref_clk_p(1'b0),.ref_clk_n(1'b0),.perst_n(1'b0),.rxn(2'b0),.rxp(2'b0),
        .pixclk_in(pixel_clk),.vs_in(vs),.hs_in(hs),.de_in(de),
        .r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),.hd_sda(hd_sda));
    wire [27:0] axi_awaddr=dut.awaddr,axi_araddr=dut.araddr;
    wire axi_awvalid=dut.awvalid,axi_awready=dut.awready,axi_arvalid=dut.arvalid,axi_arready=dut.arready;
    wire axi_wready=dut.wready;
    wire [3:0] axi_awlen=dut.awlen;
    wire [127:0] axi_wdata=dut.wdata;
    wire [15:0] axi_wstrb=dut.wstrb;
    `define NETWORK_CPU dut.u_board.u_soc
    `define NETWORK_MEMORY dut.u_video.u_hdmi_fifo.u_ddr3
    `define NETWORK_MEMORY_BASE 32'h04000000
    `define NETWORK_BOARD_STAGING
    `include "ai_network_checks.vh"
    generate if(PREPROCESS)begin:g_source
        integer x,y,frames=0;
        initial begin
            wait(rst_n);
            while(!dut.u_video.u_preprocess.cpu_held)begin
                @(negedge pixel_clk);vs=1;de=0;
                repeat(5*2200)@(negedge pixel_clk);
                vs=0;repeat(40*2200)@(negedge pixel_clk);
                for(y=0;y<1080 && !dut.u_video.u_preprocess.cpu_held;y=y+1)
                    for(x=0;x<2200 && !dut.u_video.u_preprocess.cpu_held;x=x+1)begin
                        @(negedge pixel_clk);de=x<1919;hs=x>=2008 && x<2052;
                        rgb={8'((y*7+x*3)&255),8'((y*7+x*3+53)&255),8'((y*7+x*3+106)&255)};
                    end
                de=0;hs=0;frames=frames+1;
                $display("PREPROCESS source_frame=%0d held=%b",frames,dut.u_video.u_preprocess.cpu_held);$fflush();
                if(frames>20)$fatal(1,"hardware preprocessor did not capture a real source frame");
            end
        end
        reg [31:0] tensor_cursor;
        always @(posedge core_clk)if(rst_n)begin
            if(dut.u_video.tensor_awvalid && dut.u_video.tensor_awready)
                tensor_cursor={3'b0,dut.u_video.tensor_awaddr,1'b0};
            if(dut.u_video.tensor_wready)begin
                if(tensor_cursor!=32'h07f00000+net_stage_words*16 || net_launches!=0)
                    $fatal(1,"hardware tensor address/order mismatch %h",tensor_cursor);
                if(dut.u_video.tensor_write_data!==`NETWORK_MEMORY.load_word(28'((`NETWORK_MEMORY_BASE+net_source+net_stage_words*16)>>1)))
                    $fatal(1,"hardware preprocessing mismatch at tensor word %0d",net_stage_words);
                net_stage_words=net_stage_words+1;tensor_cursor=tensor_cursor+16;
            end
        end
    end endgenerate
    always @(posedge clk)if(rst_n)begin
        if(dut.u_board.u_soc.bus_err || dut.fault)$fatal(1,"board CPU/shared-DDR fault");
        if(dut.u_board.u_soc.dev_we && dut.u_board.u_soc.dev_addr_wr==32'h30000)begin
            if(dut.u_board.u_soc.dev_wdata!=1)$fatal(1,"board runtime exit=%h",dut.u_board.u_soc.dev_wdata);
            task_check_finish;
            if(net_stage_words!=18432 || net_bound_reads==0)$fatal(1,"live input staging/binding not exercised");
            $display("PASS board_ai_ddr staged_bytes=%0d rebound_read_bursts=%0d physical_offset=04000000 preprocess=%0d",net_stage_words*16,net_bound_reads,PREPROCESS);
            $finish;
        end
    end
    initial begin repeat(6)@(negedge clk);key_n=1;end
    real limit_ns=120000000000.0;
    initial begin
        if($value$plusargs("global_timeout_ns=%f",limit_ns))begin end
        #(limit_ns);$fatal(1,"board full-network simulation timeout");
    end
endmodule
