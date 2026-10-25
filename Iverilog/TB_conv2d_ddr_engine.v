`timescale 1ns/1ps
module TB_conv2d_ddr_engine;
    reg ref_clk=0, rst_n=0;
    always #20 ref_clk=~ref_clk;
    wire core_clk, ddr_init_done;
    wire clk=core_clk;
    reg cmd_valid=0, clear_status=0;
    wire cmd_ready,busy,done,error;
    wire [3:0] error_code;
    reg [31:0] cfg_input_addr=0,cfg_weight_addr=0,cfg_bias_addr=0,cfg_output_addr=0;
    reg [15:0] cfg_in_h=0,cfg_in_w=0,cfg_in_ch=0,cfg_out_ch=0;
    reg [1:0] cfg_kernel=1,cfg_stride=1,cfg_padding=0;
    reg cfg_bias_enable=0;
    wire [31:0] out_h,out_w,total_cycles,mac_issues;
    wire [27:0] axi_awaddr, axi_araddr;
    wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid;
    wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen;
    wire axi_awready, axi_arready, axi_wready, axi_wusero_last;
    wire [3:0] axi_wusero_id, axi_rid;
    wire [127:0] axi_wdata, axi_rdata;
    wire [15:0] axi_wstrb;
    wire axi_rlast, axi_rvalid;

    wire dma_cmd_valid,dma_cmd_ready,dma_cmd_write,dma_done,dma_error,dma_fault;
    wire [31:0] dma_cmd_addr,dma_cmd_len;
    wire [3:0] dma_error_code;
    wire dma_wr_valid,dma_wr_ready,dma_rd_valid,dma_rd_ready;
    wire [127:0] dma_wr_data,dma_rd_data;
    wire dma_initialized=ddr_init_done;
    conv2d_ddr_engine dut (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cfg_input_addr(cfg_input_addr),.cfg_weight_addr(cfg_weight_addr),
        .cfg_bias_addr(cfg_bias_addr),.cfg_output_addr(cfg_output_addr),
        .cfg_in_h(cfg_in_h),.cfg_in_w(cfg_in_w),.cfg_in_ch(cfg_in_ch),.cfg_out_ch(cfg_out_ch),
        .cfg_kernel(cfg_kernel),.cfg_stride(cfg_stride),.cfg_padding(cfg_padding),
        .cfg_bias_enable(cfg_bias_enable),.clear_status(clear_status),.busy(busy),.done(done),
        .error(error),.error_code(error_code),.out_h(out_h),.out_w(out_w),
        .total_cycles(total_cycles),.mac_issues(mac_issues),
        .dma_cmd_valid(dma_cmd_valid),
        .dma_cmd_ready(dma_cmd_ready),
        .dma_cmd_write(dma_cmd_write),
        .dma_cmd_addr(dma_cmd_addr),
        .dma_cmd_len(dma_cmd_len),
        .dma_done(dma_done),
        .dma_error(dma_error),
        .dma_fault(dma_fault),
        .dma_initialized(dma_initialized),
        .dma_error_code(dma_error_code),
        .dma_wr_valid(dma_wr_valid),
        .dma_wr_ready(dma_wr_ready),
        .dma_wr_data(dma_wr_data),
        .dma_rd_valid(dma_rd_valid),
        .dma_rd_ready(dma_rd_ready),
        .dma_rd_data(dma_rd_data)
    );
    ddr_block_transfer #(.TIMEOUT_CYCLES(2048)) transfer (
        .core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(ddr_init_done),
        .cmd_valid(dma_cmd_valid),.cmd_ready(dma_cmd_ready),.cmd_write(dma_cmd_write),
        .cmd_addr(dma_cmd_addr),.cmd_len(dma_cmd_len),.clear_status(1'b0),.busy(),
        .done(dma_done),.error(dma_error),.fault(dma_fault),.error_code(dma_error_code),
        .wr_valid(dma_wr_valid),.wr_ready(dma_wr_ready),.wr_data(dma_wr_data),
        .rd_valid(dma_rd_valid),.rd_ready(dma_rd_ready),.rd_data(dma_rd_data),.rd_last(),
        .axi_awaddr(axi_awaddr),
        .axi_awuser_ap(axi_awuser_ap),
        .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr),
        .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_rdata(axi_rdata),
        .axi_rid(axi_rid),
        .axi_rlast(axi_rlast),
        .axi_rvalid(axi_rvalid)
    );
    ddr3 memory (
        .ref_clk(ref_clk), .resetn(rst_n), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id), .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(ref_clk), .apb_rst_n(rst_n), .apb_sel(1'b0), .apb_enable(1'b0),
        .apb_addr(8'd0), .apb_write(1'b0), .apb_wdata(16'd0),
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1),
        .dbg_gpll_scan_rst(1'b0), .samp_position_dyn_adj(1'b0), .wrcal_position_dyn_adj(1'b0),
        .init_samp_position_even(16'd0), .init_samp_position_odd(16'd0),
        .init_wrcal_position(16'd0), .init_slip_step(8'd0), .init_read_clk_ctrl(6'd0),
        .force_read_clk_ctrl(1'b0), .debug_cpd_offset_adj(1'b0),
        .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'd0),
        .ck_dly_en(1'b0), .init_ck_dly_step(8'd0)
    );


    reg [383:0] jobs[0:255];
    reg [159:0] initial_memory[0:65535];
    reg [127:0] golden[0:65535];
    integer job_count,initial_count,golden_count,job,n,polls,checked=0;
    integer init_base,init_words,gold_base,output_words,expected_issues;
    integer aw_count=0,ar_count=0,writes=0;
    reg checking=0;
    reg [31:0] output_start,write_cursor;
    reg [127:0] observed;
    always @(posedge clk) if(rst_n) begin
        if(axi_awvalid && axi_awready) begin aw_count=aw_count+1;write_cursor={axi_awaddr,1'b0};end
        if(axi_arvalid && axi_arready) ar_count=ar_count+1;
        if(checking && axi_wready) begin
            if(write_cursor<output_start || write_cursor>=output_start+output_words*16 ||
                axi_wstrb!==16'hffff || axi_wdata!==golden[gold_base+(write_cursor-output_start)/16])
                $fatal(1,"native output mismatch job=%0d byte=%h data=%h",job,write_cursor,axi_wdata);
            write_cursor=write_cursor+16;writes=writes+1;
        end
    end
    task launch;
        input integer index;
        begin
            @(negedge clk); job=index;
            cfg_in_h=jobs[job][15:0];cfg_in_w=jobs[job][31:16];cfg_in_ch=jobs[job][47:32];cfg_out_ch=jobs[job][63:48];
            cfg_kernel=jobs[job][65:64];cfg_stride=jobs[job][67:66];cfg_padding=jobs[job][69:68];cfg_bias_enable=jobs[job][70];
            cfg_input_addr=jobs[job][127:96];cfg_weight_addr=jobs[job][159:128];
            cfg_bias_addr=jobs[job][191:160];cfg_output_addr=jobs[job][223:192];
            cmd_valid=1;
            do @(posedge clk);while(!cmd_ready);
            @(negedge clk);cmd_valid=0;
            // 后续执行必须使用已锁存配置。
            cfg_in_h=0;cfg_in_w=0;cfg_in_ch=0;cfg_out_ch=0;cfg_input_addr=32'hdeadbeef;
        end
    endtask
    task run_layer;
        input integer index;
        begin
            job=index;
            init_base=jobs[job][255:224];init_words=jobs[job][287:256];
            gold_base=jobs[job][319:288];output_words=jobs[job][351:320];expected_issues=jobs[job][383:352];
            output_start=jobs[job][223:192];
            for(n=0;n<init_words;n=n+1)
                memory.store_word(initial_memory[init_base+n][159:128]>>1,initial_memory[init_base+n][127:0],16'hffff);
            checking=1;writes=0;
            launch(job);
            polls=0;
            while(busy) begin @(negedge clk);polls=polls+1;if(polls>2000000)$fatal(1,"engine timeout");end
            checking=0;
            if(!done || error || dma_fault || writes!=output_words || mac_issues!=expected_issues)
                $fatal(1,"engine status job=%0d done=%b error=%b code=%d writes=%0d/%0d issues=%0d/%0d",job,done,error,error_code,writes,output_words,mac_issues,expected_issues);
            for(n=0;n<output_words;n=n+1) begin
                observed=memory.load_word((output_start+n*16)>>1);
                if(observed!==golden[gold_base+n])$fatal(1,"DDR readback mismatch");checked=checked+1;
            end
            // 输入/权重/偏置及输出两侧的哨兵不允许改变。
            for(n=0;n<init_words;n=n+1) begin
                observed=memory.load_word(initial_memory[init_base+n][159:128]>>1);
                if(observed!==initial_memory[init_base+n][127:0])$fatal(1,"readonly/guard data modified");
            end
            $display("LAYER %0d cycles=%0d issues=%0d",job,total_cycles,mac_issues);
        end
    endtask
    task bad_config;
        input integer which;
        input [3:0] code;
        integer before_count;
        begin
            @(negedge clk);
            cfg_in_h=3;cfg_in_w=3;cfg_in_ch=3;cfg_out_ch=5;
            cfg_kernel=3;cfg_stride=1;cfg_padding=1;cfg_bias_enable=1;
            cfg_input_addr=32'h7f0;cfg_weight_addr=32'h1fff0;cfg_bias_addr=32'h40000;cfg_output_addr=32'h807f0;
            case(which)
                0:cfg_in_h=0;
                1:cfg_kernel=2;
                2:cfg_stride=0;
                3:cfg_padding=2;
                4:cfg_input_addr=1;
                5:cfg_bias_addr=1;
                6:cfg_input_addr=32'h1ffffff0;
                7:cfg_output_addr=cfg_input_addr;
                8:begin cfg_in_h=1;cfg_in_w=1;cfg_padding=0;end
                9:begin cfg_in_h=65535;cfg_in_w=65535;cfg_in_ch=65535;cfg_out_ch=65535;end
            endcase
            before_count=aw_count+ar_count;cmd_valid=1;
            @(negedge clk);cmd_valid=0;
            if(busy || done || !error || error_code!==code || aw_count+ar_count!=before_count)
                $fatal(1,"invalid engine config accepted which=%0d code=%0d",which,error_code);
            clear_status=1;@(negedge clk);clear_status=0;
            if(error || done)$fatal(1,"engine status clear failed");
        end
    endtask
    task reset_all;
        begin
            @(negedge ref_clk);rst_n=0;cmd_valid=0;checking=0;
            repeat(6)@(negedge ref_clk);rst_n=1;wait(ddr_init_done);
            repeat(3)@(negedge clk);
            if(busy || done || error || !cmd_ready)$fatal(1,"engine reset failed");
        end
    endtask
    initial begin
        if(!$value$plusargs("JOBS=%d",job_count) || !$value$plusargs("INITIAL=%d",initial_count) ||
            !$value$plusargs("GOLDEN=%d",golden_count)) $fatal(1,"missing vector sizes");
        $readmemh("jobs.mem",jobs,0,job_count-1);
        $readmemh("initial.mem",initial_memory,0,initial_count-1);
        $readmemh("golden.mem",golden,0,golden_count-1);
        repeat(6) @(negedge ref_clk);rst_n=1;wait(ddr_init_done);
        for(job=0;job<job_count;job=job+1) begin
            run_layer(job);
        end
        bad_config(0,1);bad_config(1,2);bad_config(2,2);bad_config(3,2);
        bad_config(4,4);bad_config(5,4);bad_config(6,3);bad_config(7,5);bad_config(8,2);bad_config(9,3);
        // 在 IP 流水仍有数据时共同复位，再重新装载/执行原始任务。
        launch(0);wait(dut.u_tile.issue_valid);reset_all;run_layer(0);
        // 原生读超时必须传播为错误，且共同复位前不接受新任务。
        force memory.axi_arready=1'b0;launch(0);
        polls=0;while(busy)begin @(negedge clk);polls=polls+1;if(polls>10000)$fatal(1,"fault propagation timeout");end
        if(!error || error_code!=12 || !dma_fault || cmd_ready)$fatal(1,"engine fault status mismatch");
        @(negedge ref_clk);rst_n=0;repeat(6)@(negedge ref_clk);release memory.axi_arready;
        rst_n=1;wait(ddr_init_done);repeat(3)@(negedge clk);run_layer(0);
        $display("PASS conv_ddr layers=%0d words=%0d AW=%0d AR=%0d",job_count,checked,aw_count,ar_count);
        $finish;
    end
    initial begin #300000000;$fatal(1,"global timeout");end
endmodule
