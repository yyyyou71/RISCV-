`timescale 1ns/1ps
module TB_conv2d_ddr_engine;
    parameter integer QUANT_TEST=0;
    reg ref_clk=0, rst_n=0;
    always #20 ref_clk=~ref_clk;
    wire core_clk, ddr_init_done;
    wire clk=core_clk;
    reg cmd_valid=0, clear_status=0;
    wire cmd_ready,busy,done,error;
    wire [3:0] error_code;
    reg [31:0] cfg_input_addr=0,cfg_weight_addr=0,cfg_bias_addr=0,cfg_output_addr=0;
    reg [31:0] cfg_quant_addr=0,cfg_post=0;
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
        .cfg_quant_addr(cfg_quant_addr),.cfg_post(cfg_post),
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


    reg [447:0] jobs[0:255];
    reg [159:0] initial_memory[0:65535];
    reg [127:0] golden[0:65535];
    integer job_count,initial_count,golden_count,job,n,polls,checked=0;
    integer init_base,init_words,gold_base,output_words,expected_issues;
    integer aw_count=0,ar_count=0,writes=0;
    reg checking=0;
    reg [31:0] output_start,write_cursor;
    reg [127:0] observed;
    reg [127:0] expected_native;
    integer check_byte,check_channel;
    always @(posedge clk) if(rst_n) begin
        if(axi_awvalid && axi_awready) begin aw_count=aw_count+1;write_cursor={axi_awaddr,1'b0};end
        if(axi_arvalid && axi_arready) ar_count=ar_count+1;
        if(checking && axi_wready) begin
            expected_native=golden[gold_base+(write_cursor-output_start)/16];
            if(dut.output_int8)begin
                // 当前 4 通道组之后尚未计算的字节必须为零；此前组必须保留。
                for(check_byte=0;check_byte<16;check_byte=check_byte+1)begin
                    check_channel=((write_cursor-output_start)%dut.output_pitch)+check_byte;
                    if(check_channel>=dut.co_base+4)expected_native[check_byte*8 +: 8]=0;
                end
            end
            if(write_cursor<output_start || write_cursor>=output_start+output_words*16 ||
                axi_wstrb!==16'hffff || axi_wdata!==expected_native)
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
            cfg_quant_addr=QUANT_TEST!=0 ? jobs[job][415:384] : 32'hdeadbeef;
            cfg_post=jobs[job][447:416];
            cmd_valid=1;
            do @(posedge clk);while(!cmd_ready);
            @(negedge clk);cmd_valid=0;
            // 后续执行必须使用已锁存配置。
            cfg_in_h=0;cfg_in_w=0;cfg_in_ch=0;cfg_out_ch=0;cfg_input_addr=32'hdeadbeef;
            cfg_quant_addr=32'hdeadbeef;cfg_post=32'hffffffff;
        end
    endtask
    task late_bad_quant;
        integer before_aw;
        begin
            // 第 0 组计算完后，第 1 组才发现参数错误；DONE 必须保持为零。
            for(n=0;n<jobs[0][287:256];n=n+1)
                memory.store_word(initial_memory[jobs[0][255:224]+n][159:128]>>1,
                    initial_memory[jobs[0][255:224]+n][127:0],16'hffff);
            memory.store_word((jobs[0][415:384]+64)>>1,128'h80000000,16'hffff);
            before_aw=aw_count;launch(0);
            polls=0;while(busy)begin @(negedge clk);polls=polls+1;if(polls>100000)$fatal(1,"late quant error timeout");end
            if(done || !error || error_code!=7 || dma_fault || !cmd_ready || aw_count-before_aw!=15)
                $fatal(1,"late quant error falsely completed/failed to preserve partial status");
            for(n=0;n<jobs[0][351:320];n=n+1)begin
                observed=memory.load_word((jobs[0][223:192]+n*16)>>1);
                expected_native=golden[jobs[0][319:288]+n]&128'hffffffff;
                if(observed!==expected_native)$fatal(1,"late error partial output mismatch");
            end
            clear_status=1;@(negedge clk);clear_status=0;
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
            if(QUANT_TEST!=0) for(n=0;n<output_words;n=n+1)
                memory.store_word((output_start+n*16)>>1,{16{8'ha7}},16'hffff);
            checking=1;writes=0;
            launch(job);
            polls=0;
            while(busy) begin @(negedge clk);polls=polls+1;if(polls>2000000)$fatal(1,"engine timeout");end
            checking=0;
            if(!done || error || dma_fault ||
                writes!=(QUANT_TEST!=0 ? out_h*out_w*((jobs[job][63:48]+3)/4) : output_words) || mac_issues!=expected_issues)
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
            cfg_post=0;cfg_quant_addr=0;
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
    task bad_quant;
        input integer which;
        input [3:0] code;
        integer before_writes;
        reg [127:0] record_data;
        begin
            @(negedge clk);
            cfg_in_h=1;cfg_in_w=1;cfg_in_ch=1;cfg_out_ch=1;
            cfg_kernel=1;cfg_stride=1;cfg_padding=0;cfg_bias_enable=0;
            cfg_input_addr=32'h7f0;cfg_weight_addr=32'h1fff0;cfg_output_addr=32'h807f0;
            cfg_post=1;cfg_quant_addr=32'h50000;record_data=128'd1;
            case(which)
                0:cfg_quant_addr=32'h50001;
                1:cfg_quant_addr=32'h1ffffff0;
                2:cfg_quant_addr=cfg_output_addr;
                3:cfg_post=2;
                4:cfg_post=5;
                5:record_data=128'h80000000;
                6:record_data=128'h0000006000000001;
                7:record_data=128'hffffffff00000001;
                8:record_data=128'h10000000000000001;
            endcase
            memory.store_word(28'h28000,record_data,16'hffff);
            before_writes=aw_count;cmd_valid=1;@(negedge clk);cmd_valid=0;
            polls=0;while(busy)begin @(negedge clk);polls=polls+1;if(polls>10000)$fatal(1,"bad quant timeout");end
            if(done || !error || error_code!==code || aw_count!=before_writes || dma_fault)
                $fatal(1,"bad quant status case=%0d code=%0d expected=%0d",which,error_code,code);
            clear_status=1;@(negedge clk);clear_status=0;
        end
    endtask
    task reset_all;
        begin
            @(negedge clk);rst_n=0;cmd_valid=0;checking=0;
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
        if(QUANT_TEST!=0)begin
            bad_quant(0,4);bad_quant(1,3);bad_quant(2,5);bad_quant(3,7);bad_quant(4,7);
            bad_quant(5,7);bad_quant(6,7);bad_quant(7,7);bad_quant(8,7);
            late_bad_quant;
            // 非法表测试改写过第一个量化参数，重放前恢复原始资产。
            for(n=0;n<jobs[0][287:256];n=n+1)
                memory.store_word(initial_memory[jobs[0][255:224]+n][159:128]>>1,
                    initial_memory[jobs[0][255:224]+n][127:0],16'hffff);
        end
        // 分别覆盖乘加流水或量化运算尚未完成时的共同复位。
        launch(0);
        if(QUANT_TEST!=0)wait(dut.state==15);else wait(dut.u_tile.issue_valid);
        reset_all;run_layer(0);
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
