// 由 TB_ddr_cpu_window 在 AI_TASK_PROGRAM 模式包含；只用于仿真。
reg [159:0] task_initial[0:65535];
reg [287:0] task_golden[0:65535];
integer task_initial_count,task_golden_count,task_job_count,task_expected_launches;
integer task_expected_reports,task_inject_fault=0;
integer task_n,task_reports=0,task_launches=0,task_checked=0;
reg [31:0] task_write_cursor;
reg [31:0] task_cycles=0,task_issues=0;
reg task_cpu_write=0;
reg [127:0] task_observed;
initial begin
    if(!$value$plusargs("TASK_INITIAL=%d",task_initial_count) ||
       !$value$plusargs("TASK_GOLDEN=%d",task_golden_count) ||
       !$value$plusargs("TASK_JOBS=%d",task_job_count) ||
       !$value$plusargs("TASK_LAUNCHES=%d",task_expected_launches))$fatal(1,"missing task fixtures");
    task_expected_reports=task_job_count;
    if($value$plusargs("TASK_REPORTS=%d",task_expected_reports))begin end
    if($value$plusargs("TASK_EXPECT_EXIT=%d",task_expected_exit))begin end
    if($value$plusargs("TASK_INJECT_FAULT=%d",task_inject_fault))begin end
    $readmemh("initial.mem",task_initial,0,task_initial_count-1);
    $readmemh("golden.mem",task_golden,0,task_golden_count-1);
    // DDR 稀疏表在 time 0 初始化；预装载模拟外部传输，保持原行为模型不变。
    #1;
    for(task_n=0;task_n<task_initial_count;task_n=task_n+1)
        memory.store_word(task_initial[task_n][159:128]>>1,task_initial[task_n][127:0],16'hffff);
end
initial begin
    #2;
    if(task_inject_fault!=0)begin
        wait(rst_n);
        wait(g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.owner_ai);
        force memory.axi_arready=1'b0;
    end
end
always @(posedge core_clk)if(rst_n)begin
    if(g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.core_state==3 &&
       g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_ready)task_launches=task_launches+1;
    if(g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.core_state==4 &&
       (g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_done || g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_error))begin
        task_cycles=task_cycles+g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_cycles;
        task_issues=task_issues+g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_issues;
    end
    if(axi_awvalid && axi_awready)begin
        task_write_cursor={axi_awaddr,1'b0};
        task_cpu_write=!g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.owner_ai;
        // CPU 只能写运行报告，禁止 CPU 搬运输入、参数或中间特征图。
        if(task_cpu_write && (task_write_cursor<32'h4000 || task_write_cursor>=32'h4000+task_job_count*32 || axi_awlen!=1))
            $fatal(1,"runtime CPU wrote outside report area: %h",task_write_cursor);
    end
    if(axi_wready)begin
        if(task_cpu_write && task_write_cursor[4])begin
            if(axi_wdata[31:0]!==task_cycles || axi_wdata[63:32]!==task_issues)
                $fatal(1,"runtime performance aggregation mismatch: got=%h cycles=%0d issues=%0d",axi_wdata,task_cycles,task_issues);
            task_cycles=0;task_issues=0;task_reports=task_reports+1;
        end
        task_write_cursor=task_write_cursor+16;
    end
end
task task_check_finish;
    begin
        if(task_reports!=task_expected_reports || task_launches!=task_expected_launches)
            $fatal(1,"runtime counts reports=%0d/%0d launches=%0d/%0d",task_reports,task_expected_reports,task_launches,task_expected_launches);
        if(task_inject_fault!=0 && !g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.transfer_fault)
            $fatal(1,"native fault was silently cleared by runtime");
        for(task_n=0;task_n<task_golden_count;task_n=task_n+1)begin
            task_observed=memory.load_word(task_golden[task_n][287:256]>>1);
            if(((task_observed^task_golden[task_n][127:0])&task_golden[task_n][255:128])!==128'd0)
                $fatal(1,"runtime memory mismatch byte=%h got=%h expected=%h mask=%h",
                    task_golden[task_n][287:256],task_observed,task_golden[task_n][127:0],task_golden[task_n][255:128]);
            task_checked=task_checked+1;
        end
        $display("PASS ai_tasks models=%0d launches=%0d words=%0d",task_reports,task_launches,task_checked);
    end
endtask
