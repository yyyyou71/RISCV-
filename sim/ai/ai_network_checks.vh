// 完整任务图/任意连续区间的CPU测试；文件逐条读取，避免限制为65536个DDR字。
integer net_initial,net_golden,net_tasks,net_start=0;
integer net_launches=0,net_reports=0,net_checked=0;
reg [63:0] net_outputs[0:98]; // 高32位为地址，低32位为长度。
reg [31:0] net_cycles=0,net_issues=0,net_write_cursor;
reg net_cpu_write=0;
integer net_fd,net_scan,net_n;
reg [159:0] net_record;
integer net_post_enable=0,net_post_only=0,net_post_reports=0;
reg [31:0] net_post_addr=0,net_post_bytes=0,net_post_cursor=0;
initial begin
    if($value$plusargs("POST_ENABLE=%d",net_post_enable))begin end
    if($value$plusargs("POST_ONLY=%d",net_post_only))begin end
    if($value$plusargs("POST_OUTPUT_ADDR=%d",net_post_addr))begin end
    if($value$plusargs("POST_OUTPUT_BYTES=%d",net_post_bytes))begin end
    net_post_cursor=net_post_addr;
    if(!$value$plusargs("TASK_INITIAL=%d",net_initial) || !$value$plusargs("TASK_GOLDEN=%d",net_golden) ||
       !$value$plusargs("NETWORK_TASKS=%d",net_tasks))$fatal(1,"missing network fixtures");
    if($value$plusargs("NETWORK_START=%d",net_start))begin end
    if(net_initial<=0 || net_golden<=0 || net_tasks<0 || net_tasks>99 ||
       (net_tasks==0 && !(net_post_only==1 && net_post_enable==1)) ||
       (net_post_only!=0 && net_tasks!=0))$fatal(1,"invalid network fixture counts");
    if(net_post_enable!=0 && (net_post_addr<32'h8000 || net_post_addr[3:0]!=0 ||
       net_post_bytes>9600 || net_post_bytes[4:0]!=0 || {1'b0,net_post_addr}+net_post_bytes>33'h10000))
        $fatal(1,"invalid postprocess fixture range");
    if(net_tasks>0)$readmemh("outputs.mem",net_outputs,0,net_tasks-1);
    #1; // 等DDR行为模型完成time 0的稀疏表初始化。
    net_fd=$fopen("initial.mem","r");if(net_fd==0)$fatal(1,"missing network initial.mem");
    for(net_n=0;net_n<net_initial;net_n=net_n+1)begin
        net_scan=$fscanf(net_fd,"%h",net_record);
        if(net_scan!=1 || net_record[131:128]!=0 || net_record[159:128]>=32'h20000000)$fatal(1,"bad network initial record");
        memory.store_word(28'(net_record[159:128]>>1),net_record[127:0],16'hffff);
    end
    net_scan=$fscanf(net_fd,"%h",net_record);
    if(net_scan==1 || !$feof(net_fd))$fatal(1,"unexpected extra initial data");$fclose(net_fd);
end
always @(posedge core_clk)if(rst_n)begin
    if(g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.core_state==3 &&
       g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_ready)begin
        $display("NETWORK task=%0d begin",net_start+net_launches);net_launches=net_launches+1;
    end
    if(g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.core_state==4 &&
       (g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_done || g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_error))begin
        net_cycles=net_cycles+g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_cycles;
        net_issues=net_issues+g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_issues;
        $display("NETWORK task=%0d end error=%b cycles=%0d issues=%0d",net_start+net_launches-1,
            g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_error,
            g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_cycles,g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.ai_issues);
    end
    if(axi_awvalid && axi_awready)begin
        net_write_cursor={3'd0,axi_awaddr,1'b0};net_cpu_write=!g_cpu.u_soc.u_peripheral_bus.g_ddr.u_window.owner_ai;
        if(net_cpu_write)begin
            if(axi_awlen!=1)$fatal(1,"unexpected network CPU burst");
            if(net_write_cursor==32'h4000)begin end
            else if(net_post_enable!=0 && net_write_cursor==32'h5040)begin end
            else if(net_post_enable!=0 && net_write_cursor==net_post_cursor &&
                net_write_cursor>=net_post_addr && net_write_cursor-net_post_addr<net_post_bytes)
                net_post_cursor=net_post_cursor+32;
            else $fatal(1,"network CPU wrote outside report/detection output: %h",net_write_cursor);
        end else begin
            if(net_launches<1 || net_launches>net_tasks)$fatal(1,"network write without active task");
            if(net_write_cursor<net_outputs[net_launches-1][63:32] ||
                net_write_cursor-net_outputs[net_launches-1][63:32]>=net_outputs[net_launches-1][31:0] || axi_awlen!=0)
                $fatal(1,"network AI wrote outside current task output: %h",net_write_cursor);
        end
    end
    if(axi_wready)begin
        if(axi_wstrb!==16'hffff)$fatal(1,"network partial DDR write");
        if(net_cpu_write && net_write_cursor==32'h4010)begin
            if(axi_wdata[31:0]!==net_cycles || axi_wdata[63:32]!==net_issues)$fatal(1,"network performance mismatch");
            net_reports=net_reports+1;
        end
        if(net_cpu_write && net_write_cursor==32'h5050)net_post_reports=net_post_reports+1;
        net_write_cursor=net_write_cursor+16;
    end
end
task task_check_finish;
    integer f,n,scan;
    reg [287:0] record_data;
    reg [127:0] observed;
    begin
        if(net_launches!=net_tasks || net_reports!=1)$fatal(1,"network report/launch mismatch: %0d/%0d",net_reports,net_launches);
        if(net_post_enable!=0 && (net_post_reports!=1 || net_post_cursor!=net_post_addr+net_post_bytes))
            $fatal(1,"postprocess report/output mismatch");
        f=$fopen("golden.mem","r");if(f==0)$fatal(1,"missing network golden.mem");
        for(n=0;n<net_golden;n=n+1)begin
            scan=$fscanf(f,"%h",record_data);if(scan!=1)$fatal(1,"short network golden file");
            if(record_data[259:256]!=0 || record_data[287:256]>=32'h20000000)$fatal(1,"bad network golden address");
            observed=memory.load_word(28'(record_data[287:256]>>1));
            if(((observed^record_data[127:0])&record_data[255:128])!==128'd0)
                $fatal(1,"network mismatch byte=%h got=%h expected=%h",record_data[287:256],observed,record_data[127:0]);
            net_checked=net_checked+1;
        end
        scan=$fscanf(f,"%h",record_data);
        if(scan==1 || !$feof(f))$fatal(1,"unexpected extra golden data");$fclose(f);
        if(net_post_enable!=0)begin
            // 从CPU实际写回的DDR区转储；主机工具再转换成可读的检测框JSON。
            f=$fopen("cpu_detections.mem","w");if(f==0)$fatal(1,"cannot write CPU detections");
            for(n=0;n<integer'(net_post_bytes);n=n+16)begin
                observed=memory.load_word(28'((net_post_addr+32'(n))>>1));
                $fdisplay(f,"%032h",observed);
            end
            $fclose(f);
        end
        $display("PASS ai_network start=%0d tasks=%0d words=%0d cycles=%0d issues=%0d",net_start,net_tasks,net_checked,net_cycles,net_issues);
        if(net_post_enable!=0)$display("PASS ai_postprocess records=%0d",net_post_bytes/32);
    end
endtask
