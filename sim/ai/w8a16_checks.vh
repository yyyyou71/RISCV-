// 由CPU测试台包含。外部预装DDR资产；CPU执行配置、调度及窗口读回。
reg [159:0] wide_initial[0:16383];
reg [127:0] wide_golden[0:4095];
reg [479:0] wide_jobs[0:1];
integer wide_initial_count,wide_golden_count,wide_n,wide_k,wide_checked=0;
reg [31:0] wide_cursor;
reg [127:0] wide_expected,wide_observed;
integer wide_channel,wide_byte,wide_job;
initial begin
    if(!$value$plusargs("WIDE_INITIAL=%d",wide_initial_count) ||
       !$value$plusargs("WIDE_GOLDEN=%d",wide_golden_count))$fatal(1,"missing W8A16 CPU fixtures");
    $readmemh("initial.mem",wide_initial,0,wide_initial_count-1);
    $readmemh("golden.mem",wide_golden,0,wide_golden_count-1);$readmemh("jobs.mem",wide_jobs,0,1);
    #1;for(wide_n=0;wide_n<wide_initial_count;wide_n=wide_n+1)
        memory.store_word(wide_initial[wide_n][159:128]>>1,wide_initial[wide_n][127:0],16'hffff);
end
always @(posedge clk)if(rst_n && ai_completed==1 && dev_we && dev_addr_wr==32'h31000 && dev_wdata[0])
    $fatal(1,"CPU transferred between W8A16 connected layers");
always @(posedge core_clk)if(rst_n)begin
    if(axi_awvalid && axi_awready)wide_cursor={axi_awaddr,1'b0};
    if(axi_wready)begin
        if(!g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.owner_ai)$fatal(1,"unexpected CPU DDR write");
        wide_job=ai_completed;
        if(wide_job>1 || wide_cursor<wide_jobs[wide_job][223:192] ||
           wide_cursor>=wide_jobs[wide_job][223:192]+wide_jobs[wide_job][351:320]*16)
            $fatal(1,"AI wrote outside output allocation");
        wide_expected=wide_golden[wide_jobs[wide_job][319:288]+(wide_cursor-wide_jobs[wide_job][223:192])/16];
        for(wide_byte=0;wide_byte<16;wide_byte=wide_byte+1)begin
            wide_channel=((wide_cursor-wide_jobs[wide_job][223:192])%
                (g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.g_ai.u_engine.output_pitch*2))/2+wide_byte/2;
            if(wide_channel>=g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.g_ai.u_engine.co_base+4)
                wide_expected[wide_byte*8 +: 8]=0;
        end
        if(axi_wstrb!==16'hffff || axi_wdata!==wide_expected)$fatal(1,"CPU W8A16 native write mismatch");
        wide_cursor=wide_cursor+16;
    end
end
task wide_check_finish;
    integer n,k;
    reg mutable_word;
    begin
        for(k=0;k<2;k=k+1)for(n=0;n<wide_jobs[k][351:320];n=n+1)begin
            wide_observed=memory.load_word((wide_jobs[k][223:192]+n*16)>>1);
            if(wide_observed!==wide_golden[wide_jobs[k][319:288]+n])$fatal(1,"CPU W8A16 final data mismatch");
            wide_checked=wide_checked+1;
        end
        for(n=0;n<wide_initial_count;n=n+1)begin
            mutable_word=0;
            for(k=0;k<2;k=k+1)if(wide_initial[n][159:128]>=wide_jobs[k][223:192] &&
                wide_initial[n][159:128]<wide_jobs[k][223:192]+wide_jobs[k][351:320]*16)mutable_word=1;
            if(!mutable_word && memory.load_word(wide_initial[n][159:128]>>1)!==wide_initial[n][127:0])
                $fatal(1,"CPU W8A16 modified readonly assets/guards");
        end
        $display("W8A16 CPU checked_words=%0d",wide_checked);
    end
endtask
