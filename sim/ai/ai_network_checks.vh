// 完整任务图/任意连续区间的CPU测试；文件逐条读取，避免限制为65536个DDR字。
`ifndef NETWORK_CPU
`define NETWORK_CPU g_cpu.u_soc
`endif
`ifndef NETWORK_MEMORY
`define NETWORK_MEMORY memory
`endif
`ifndef NETWORK_MEMORY_BASE
`define NETWORK_MEMORY_BASE 32'b0
`endif
integer net_initial,net_golden,net_tasks,net_start=0;
integer net_launches=0,net_reports=0,net_checked=0;
reg [63:0] net_outputs[0:98]; // 高32位为地址，低32位为长度。
reg [31:0] net_cycles=0,net_issues=0,net_write_cursor;
reg net_cpu_write=0;
integer net_fd,net_scan,net_n;
reg [159:0] net_record;
integer net_post_enable=0,net_post_only=0,net_post_reports=0;
reg [31:0] net_post_addr=0,net_post_bytes=0,net_post_cursor=0;
`ifdef NETWORK_BOARD_STAGING
integer net_stage_words=0,net_bound_reads=0;
reg [31:0] net_source=0;
localparam [31:0] NET_LIVE=32'h03f00000,NET_INPUT_BYTES=294912;
initial if(!$value$plusargs("BOARD_INPUT_SOURCE=%d",net_source))$fatal(1,"missing board source address");
`endif
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
        `NETWORK_MEMORY.store_word(28'((net_record[159:128]+`NETWORK_MEMORY_BASE)>>1),net_record[127:0],16'hffff);
    end
    net_scan=$fscanf(net_fd,"%h",net_record);
    if(net_scan==1 || !$feof(net_fd))$fatal(1,"unexpected extra initial data");$fclose(net_fd);
end
always @(posedge core_clk)if(rst_n)begin
    if(`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.core_state==3 &&
       `NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_ready)begin
`ifdef NETWORK_BOARD_STAGING
        if(net_stage_words!=18432)$fatal(1,"AI started before live tensor was completely staged");
`endif
        $display("NETWORK task=%0d begin",net_start+net_launches);net_launches=net_launches+1;
        $fflush();
    end
    if(`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.core_state==4 &&
       (`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_done || `NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_error))begin
        net_cycles=net_cycles+`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_cycles;
        net_issues=net_issues+`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_issues;
        $display("NETWORK task=%0d end error=%b cycles=%0d issues=%0d",net_start+net_launches-1,
            `NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_error,
            `NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_cycles,`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.ai_issues);$fflush();
    end
    if(axi_awvalid && axi_awready)begin
        net_write_cursor={3'd0,axi_awaddr,1'b0};net_cpu_write=!`NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.owner_ai;
        if(net_cpu_write)begin
`ifdef NETWORK_BOARD_STAGING
            if(net_write_cursor>=NET_LIVE && net_write_cursor<NET_LIVE+NET_INPUT_BYTES)begin
`ifdef NETWORK_BOARD_PREPROCESS
                $fatal(1,"CPU overwrote hardware-produced tensor");
`endif
                if(net_launches!=0 || axi_awlen!=15 || net_write_cursor!=NET_LIVE+net_stage_words*16)
                    $fatal(1,"unexpected live input staging burst");
            end else begin
`endif
            if(axi_awlen!=1)$fatal(1,"unexpected network CPU burst");
            if(net_write_cursor==32'h4000)begin end
            else if(net_post_enable!=0 && net_write_cursor==32'h5040)begin end
            else if(net_post_enable!=0 && net_write_cursor==net_post_cursor &&
                net_write_cursor>=net_post_addr && net_write_cursor-net_post_addr<net_post_bytes)
                net_post_cursor=net_post_cursor+32;
            else $fatal(1,"network CPU wrote outside report/detection output: %h",net_write_cursor);
`ifdef NETWORK_BOARD_STAGING
            end
`endif
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
`ifdef NETWORK_BOARD_STAGING
        if(net_cpu_write && net_write_cursor>=NET_LIVE && net_write_cursor<NET_LIVE+NET_INPUT_BYTES)begin
            if(axi_wdata!==`NETWORK_MEMORY.load_word(28'((`NETWORK_MEMORY_BASE+net_source+net_write_cursor-NET_LIVE)>>1)))
                $fatal(1,"live DDR staging pixel data mismatch at %h",net_write_cursor);
            net_stage_words=net_stage_words+1;
        end
`endif
        net_write_cursor=net_write_cursor+16;
    end
end
`ifdef NETWORK_BOARD_STAGING
always @(posedge core_clk)if(rst_n && axi_arvalid && axi_arready && `NETWORK_CPU.u_peripheral_bus.g_ddr.u_window.owner_ai)begin
    if({3'b0,axi_araddr,1'b0}>=net_source && {3'b0,axi_araddr,1'b0}<net_source+NET_INPUT_BYTES)
        $fatal(1,"AI read original tensor instead of rebound live input");
    if({3'b0,axi_araddr,1'b0}>=NET_LIVE && {3'b0,axi_araddr,1'b0}<NET_LIVE+NET_INPUT_BYTES)net_bound_reads=net_bound_reads+1;
end
`endif
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
            observed=`NETWORK_MEMORY.load_word(28'((record_data[287:256]+`NETWORK_MEMORY_BASE)>>1));
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
                observed=`NETWORK_MEMORY.load_word(28'((net_post_addr+32'(n)+`NETWORK_MEMORY_BASE)>>1));
                $fdisplay(f,"%032h",observed);
            end
            $fclose(f);
        end
        $display("PASS ai_network start=%0d tasks=%0d words=%0d cycles=%0d issues=%0d",net_start,net_tasks,net_checked,net_cycles,net_issues);
        if(net_post_enable!=0)$display("PASS ai_postprocess records=%0d",net_post_bytes/32);
    end
endtask
