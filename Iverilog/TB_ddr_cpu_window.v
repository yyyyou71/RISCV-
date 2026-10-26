`timescale 1ns/1ps
// 同一环境分别验证外设寄存器接口、完整 CPU 裸机访问。DDR 始终使用原始行为模型。
module TB_ddr_cpu_window;
    parameter integer CPU_TEST = 0;
    parameter integer WINDOW_ENABLE = 1;
    parameter integer AI_ENABLE = 0;
    parameter integer AI_ACT_WIDTH = 8;
    reg ref_clk = 0, clk = 0, rst_n = 0;
    integer cpu_half_ns = 20;
    initial if ($value$plusargs("cpu_half_ns=%d", cpu_half_ns)) begin end
    always #20 ref_clk = ~ref_clk;
    always #(cpu_half_ns) clk = ~clk;
    wire core_clk, ddr_init_done, uart_txd;
    reg host_we = 0, host_re = 0;
    reg [31:0] host_wr = 0, host_rd = 0, host_data = 0;
    reg [1:0] host_size = 2;
    wire dev_we, dev_re;
    wire [31:0] dev_addr_wr, dev_addr_rd, dev_wdata, dev_rdata;
    wire [1:0] dev_size;
    wire [27:0] axi_awaddr, axi_araddr;
    wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid;
    wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen;
    wire axi_awready, axi_arready, axi_wready, axi_wusero_last;
    wire [3:0] axi_wusero_id, axi_rid;
    wire [127:0] axi_wdata, axi_rdata;
    wire [15:0] axi_wstrb;
    wire axi_rlast, axi_rvalid;


    integer aw_count = 0, ar_count = 0;
`ifdef AI_TASK_PROGRAM
    integer task_expected_exit=1;
`endif
`ifdef AI_PROGRAM
    integer ai_completed=0;
`endif
    generate if (CPU_TEST != 0) begin : g_cpu
        wire bus_err;
        soc #(.ENABLE_DDR(1),.ENABLE_AI(AI_ENABLE),.AI_ACT_WIDTH(AI_ACT_WIDTH)) u_soc (
            .clk(clk), .rst_n(rst_n), .uart_txd(uart_txd), .bus_err(bus_err),
            .core_clk(core_clk), .ddr_init_done(ddr_init_done),
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
        assign dev_we = u_soc.dev_we;
        assign dev_re = u_soc.dev_re;
        assign dev_addr_wr = u_soc.dev_addr_wr;
        assign dev_addr_rd = u_soc.dev_addr_rd;
        assign dev_wdata = u_soc.dev_wdata;
        assign dev_rdata = u_soc.dev_rdata;
        assign dev_size = u_soc.dev_size;
`ifdef AI_PROGRAM
        always @(posedge core_clk) if(rst_n && u_soc.u_peripheral_bus.g_ddr.u_window.core_state==4 &&
            u_soc.u_peripheral_bus.g_ddr.u_window.ai_done) ai_completed=ai_completed+1;
`ifdef AI_CHAIN
`ifndef AI_W8A16
        // 两层之间禁止 CPU 通过窗口搬运特征图；第二层必须直接读取 DDR 中间结果。
        always @(posedge clk) if(rst_n && ai_completed==1 && dev_we && dev_addr_wr==32'h31000 && dev_wdata[0])
            $fatal(1,"CPU copied/intervened between connected layers");
`endif
`endif
`endif
        always @(posedge clk) if (rst_n) begin
            if (bus_err) $fatal(1, "CPU bus error");
            if (dev_we && dev_addr_wr == 32'h30000) begin
`ifdef AI_TASK_PROGRAM
                if (dev_wdata !== task_expected_exit) $fatal(1,"runtime exit=%h expected=%h",dev_wdata,task_expected_exit);
                task_check_finish;
`else
                if (dev_wdata !== 1) $fatal(1, "CPU test failed code=%h", dev_wdata);
                if (aw_count < 16 || ar_count < 16) $fatal(1, "CPU did not exercise DDR");
`ifdef AI_PROGRAM
                if(ai_completed!=2) $fatal(1,"AI engine not executed twice: %0d",ai_completed);
`ifdef AI_CHAIN
`ifdef AI_W8A16
                wide_check_finish;
`endif
                $display("PASS ai_chain layers=%0d aw=%0d ar=%0d",ai_completed,aw_count,ar_count);
`else
                $display("PASS ai_cpu layers=%0d aw=%0d ar=%0d",ai_completed,aw_count,ar_count);
`endif
`else
                $display("PASS cpu_mmio aw=%0d ar=%0d", aw_count, ar_count);
`endif
`endif
                $finish;
            end
        end
    end else begin : g_host
        assign dev_we = host_we; assign dev_re = host_re;
        assign dev_addr_wr = host_wr; assign dev_addr_rd = host_rd;
        assign dev_wdata = host_data; assign dev_size = host_size;
        peripheral_bus #(.ENABLE_DDR(WINDOW_ENABLE),.ENABLE_AI(AI_ENABLE),.AI_ACT_WIDTH(AI_ACT_WIDTH), .DDR_TIMEOUT_CYCLES(128)) u_bus (
            .clk(clk), .rst_n(rst_n), .uart_txd(uart_txd),
            .dev_we(dev_we), .dev_re(dev_re), .dev_addr_wr(dev_addr_wr),
            .dev_addr_rd(dev_addr_rd), .dev_wdata(dev_wdata), .dev_size(dev_size),
            .dev_rdata(dev_rdata), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
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
    end endgenerate
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

`ifdef AI_TASK_PROGRAM
    `include "ai_task_checks.vh"
`endif
`ifdef AI_W8A16
    `include "w8a16_checks.vh"
`endif

    localparam [31:0] CTRL = 32'h31000, STATUS = 32'h31004,
                     ADDRESS = 32'h31008, LENGTH = 32'h3100c,
                     ERROR_CODE = 32'h31010, DATA = 32'h31100;
    reg [95:0] commands [0:2047];
    reg [127:0] vectors [0:32767];
    integer job_count, job, k, checked = 0;
    integer remaining = 0, segment, native_index = 0;
    reg [31:0] cursor;
    reg check_native = 0, writing;
    reg [31:0] value;

    // 地址与 W 数据另外核对，避免同一种错误同时污染写入和读回而假通过。
    always @(posedge core_clk) if (rst_n) begin
        if (axi_awvalid && axi_awready) aw_count = aw_count + 1;
        if (axi_arvalid && axi_arready) ar_count = ar_count + 1;
        if (check_native && ((axi_awvalid && axi_awready) || (axi_arvalid && axi_arready))) begin
            segment = 2048 - cursor % 2048;
            if (segment > remaining) segment = remaining;
            if (writing) begin
                if (!axi_awvalid || axi_awaddr !== (cursor >> 1) || axi_awlen !== (segment/16-1))
                    $fatal(1, "AW address mismatch");
            end else if (!axi_arvalid || axi_araddr !== (cursor >> 1) || axi_arlen !== (segment/16-1))
                $fatal(1, "AR address mismatch");
            cursor = cursor + segment; remaining = remaining - segment;
        end
        if (check_native && writing && axi_wready) begin
            if (axi_wstrb !== 16'hffff || axi_wdata !== vectors[job*16+native_index])
                $fatal(1, "W payload mismatch job=%0d beat=%0d", job, native_index);
            native_index = native_index + 1;
        end
    end

    task put;
        input [31:0] address, data;
        begin
            @(negedge clk); host_wr = address; host_data = data; host_we = 1;
            @(negedge clk); host_we = 0;
        end
    endtask
    task get;
        input [31:0] address;
        output [31:0] data;
        begin
            @(negedge clk); host_rd = address; host_re = 1;
            @(negedge clk); data = dev_rdata; host_re = 0;
        end
    endtask
    task wait_result;
        input [3:0] code;
        integer polls;
        reg [31:0] status_value, error_value;
        begin
            polls = 0; status_value = 1;
            while (status_value[0]) begin
                get(STATUS, status_value); polls = polls + 1;
                if (polls > 5000) $fatal(1, "MMIO busy timeout");
            end
            if (status_value[3] || status_value[2] !== (code != 0) || status_value[1] !== (code == 0))
                $fatal(1, "status mismatch status=%h expected_code=%0d", status_value, code);
            get(ERROR_CODE, error_value);
            if (error_value !== {28'd0,code}) $fatal(1, "error code mismatch");
        end
    endtask
    task invalid;
        input [31:0] address, length;
        input [3:0] code;
        integer before_count;
        begin
            before_count = aw_count + ar_count;
            put(ADDRESS,address); put(LENGTH,length); put(CTRL,1); wait_result(code);
            if (aw_count + ar_count != before_count) $fatal(1, "invalid command issued DDR access");
            put(CTRL,4); get(STATUS,value);
            if ((value & 15) != 0) $fatal(1, "clear failed");
        end
    endtask
    initial begin
        #200000000;
        $fatal(1, "global timeout");
    end
    initial begin
        repeat(6) @(negedge clk); rst_n = 1;
        if (CPU_TEST == 0) begin
            if (WINDOW_ENABLE == 0) begin
                repeat(4) @(negedge clk);
                put(ADDRESS,32'h100); put(LENGTH,16); put(CTRL,3);
                get(STATUS,value); if (value !== 0) $fatal(1,"disabled window responds");
                get(32'h30104,value); if (value !== 1) $fatal(1,"disabled mode UART failed");
                if (axi_awvalid !== 0 || axi_arvalid !== 0 || axi_wstrb !== 0)
                    $fatal(1,"disabled mode emitted requests");
                $display("PASS disabled_ddr_uart_compatible"); $finish;
            end
            if (!$value$plusargs("JOBS=%d",job_count)) $fatal(1,"missing jobs");
            $readmemh("commands.mem", commands, 0, job_count-1);
            $readmemh("data.mem", vectors, 0, job_count*16-1);
            // 初始化前提交立即报错；不会阻塞 CPU 等待 DDR。
            repeat(4) @(negedge clk);
            put(CTRL,1); wait_result(8);
            wait(ddr_init_done); repeat(6) @(negedge clk);
            get(STATUS,value); if (value[5:4] !== 3) $fatal(1,"init/ready missing");
            get(DATA,value); if (value !== 0) $fatal(1,"uninitialized window not zero");
            get(32'h30104,value); if (value !== 1) $fatal(1,"UART status changed");
            // 非字宽写、未对齐写和未实现地址不能修改配置。
            host_size = 0; put(ADDRESS,32'h123); host_size = 2;
            put(ADDRESS+1,32'h456); get(ADDRESS,value);
            if (value !== 0) $fatal(1,"bad access modified address");
            host_size = 0; get(STATUS,value); host_size = 2;
            if (value !== 0) $fatal(1,"bad read size accepted");
            for (job = 0; job < job_count; job = job + 1) begin
                writing = commands[job][64]; cursor = commands[job][63:32];
                remaining = commands[job][31:0]; native_index = 0;
                // 读前清窗口，防止只回读了残留数据。
                for (k = 0; k < 64; k = k + 1)
                    put(DATA+k*4, writing ? vectors[job*16+k/4][(k%4)*32 +: 32] : 32'hbadcafe0);
                put(ADDRESS,cursor); put(LENGTH,remaining);
                check_native = 1;
                put(CTRL,writing ? 3 : 1);
                get(STATUS,value); if (!value[0] || value[1]) $fatal(1,"no immediate busy");
                // 快速发出的非法并发写不得改变正在执行的请求/邮箱。
                if (commands[job][31:0] == 256) begin
                    put(ADDRESS,32'hdeadbeef); put(DATA,32'hdeadbeef); put(CTRL,1);
                end
                wait_result(0); check_native = 0;
                if (remaining != 0) $fatal(1,"missing native command");
                get(ADDRESS,value); if (value !== commands[job][63:32]) $fatal(1,"busy config write accepted");
                if (!writing)
                    for (k = 0; k < commands[job][31:0]/4; k = k + 1) begin
                        get(DATA+k*4,value);
                        if (value !== vectors[job*16+k/4][(k%4)*32 +: 32])
                            $fatal(1,"window mismatch job=%0d word=%0d got=%h",job,k,value);
                        checked = checked + 1;
                    end
            end
            invalid(0,0,1); invalid(0,272,1); invalid(1,16,2);
            invalid(0,17,2); invalid(32'h1ffffff0,32,3);
            // 共同复位后，邮箱翻转位、有效字标记和状态均应重新开始。
            @(negedge clk); rst_n = 0; repeat(6) @(negedge clk); rst_n = 1;
            wait(ddr_init_done); repeat(6) @(negedge clk);
            get(STATUS,value); if (value !== 48) $fatal(1,"reset status mismatch");
            get(DATA,value); if (value !== 0) $fatal(1,"reset validity mismatch");
            put(ADDRESS,32'h100); put(LENGTH,16); put(CTRL,1); wait_result(0);
            get(DATA,value); if (value !== vectors[0][31:0]) $fatal(1,"post reset read mismatch");
            // 写邮箱中从未初始化的字必须按零发送，不允许 X 进入 DDR。
            @(negedge clk); rst_n = 0; repeat(6) @(negedge clk); rst_n = 1;
            wait(ddr_init_done); repeat(6) @(negedge clk);
            put(ADDRESS,32'h40000); put(LENGTH,16); put(CTRL,3); wait_result(0);
            put(CTRL,1); wait_result(0);
            for (k = 0; k < 4; k = k + 1) begin
                get(DATA+k*4,value); if (value !== 0) $fatal(1,"uninitialized write data not zero");
            end
            // 请求已经跨域、但 AW 尚未握手时共同复位，不能出现幽灵完成。
            force memory.axi_awready = 1'b0;
            put(CTRL,3); wait(axi_awvalid);
            @(negedge clk); rst_n = 0; repeat(6) @(negedge clk);
            release memory.axi_awready; rst_n = 1;
            wait(ddr_init_done); repeat(6) @(negedge clk);
            get(STATUS,value); if (value !== 48) $fatal(1,"busy reset status mismatch");
            put(ADDRESS,32'h100); put(LENGTH,16); put(CTRL,1); wait_result(0);
            get(DATA,value); if (value !== vectors[0][31:0]) $fatal(1,"busy reset recovery failed");
            // 看门狗故障跨域返回后，清状态和重新启动都不能解除故障锁定。
            force memory.axi_awready = 1'b0;
            put(CTRL,3);
            value = 1;
            while (value[0]) get(STATUS,value);
            if (value[4:0] !== 5'b01100) $fatal(1,"fault status mismatch %h",value);
            get(ERROR_CODE,value); if (value !== 4) $fatal(1,"fault code mismatch");
            put(CTRL,4); put(CTRL,1); get(STATUS,value);
            if (value[4:0] !== 5'b01100) $fatal(1,"fault cleared without reset");
            @(negedge clk); rst_n = 0; repeat(6) @(negedge clk);
            release memory.axi_awready; rst_n = 1;
            wait(ddr_init_done); repeat(6) @(negedge clk);
            put(ADDRESS,32'h100); put(LENGTH,16); put(CTRL,1); wait_result(0);
            get(DATA,value); if (value !== vectors[0][31:0]) $fatal(1,"fault recovery failed");
            $display("PASS mmio_cdc jobs=%0d read_words=%0d cpu_half_ns=%0d",job_count,checked,cpu_half_ns);
            $finish;
        end
    end
endmodule
