`timescale 1ns/1ps

// 使用可控的原生接口从端注入异常，单独验证不能由正常 DDR 模型产生的故障。
// 实际系统恢复时必须共同复位 DDR IP；本文件的从端信号也在每次复位时清空。
module TB_ddr_block_transfer_faults;
    reg core_clk = 0;
    always #5 core_clk = ~core_clk;
    reg rst_n = 0, ddr_init_done = 0;
    reg cmd_valid = 0, cmd_write = 0, clear_status = 0;
    reg [31:0] cmd_addr = 0, cmd_len = 0;
    wire cmd_ready, busy, done, error, fault;
    wire [3:0] error_code;
    reg wr_valid = 0, rd_ready = 0;
    reg [127:0] wr_data = 0;
    wire wr_ready, rd_valid, rd_last;
    wire [127:0] rd_data;
    wire [27:0] axi_awaddr, axi_araddr;
    wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid;
    wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen;
    wire [127:0] axi_wdata;
    wire [15:0] axi_wstrb;
    reg axi_awready = 0, axi_arready = 0, axi_wready = 0, axi_wusero_last = 0;
    reg [3:0] axi_wusero_id = 5, axi_rid = 5;
    reg [127:0] axi_rdata = 0;
    reg axi_rlast = 0, axi_rvalid = 0;
    integer checked_faults = 0, fast_commands = 0, k;
    reg [27:0] saved_address;
    reg [3:0] saved_length;

    ddr_block_transfer #(.TIMEOUT_CYCLES(32), .AXI_ID(4'h5)) dut (.*);

    task reset_all;
        begin
            @(negedge core_clk);
            rst_n = 0; ddr_init_done = 0;
            cmd_valid = 0; wr_valid = 0; rd_ready = 0; clear_status = 0;
            axi_awready = 0; axi_arready = 0; axi_wready = 0;
            axi_wusero_last = 0; axi_wusero_id = 5;
            axi_rvalid = 0; axi_rlast = 0; axi_rid = 5; axi_rdata = 0;
            repeat(3) @(negedge core_clk);
            rst_n = 1;
            repeat(3) begin
                @(negedge core_clk);
                if (cmd_ready || busy || error || done) $fatal(1, "initialization gating");
            end
            ddr_init_done = 1;
            @(negedge core_clk);
            if (!cmd_ready || error || fault) $fatal(1, "reset recovery");
        end
    endtask

    task send_command;
        input direction;
        input [31:0] length;
        begin
            @(negedge core_clk);
            cmd_valid = 1; cmd_write = direction; cmd_addr = 32'h7f0; cmd_len = length;
            @(posedge core_clk);
            if (!cmd_ready) $fatal(1, "command not accepted");
            @(negedge core_clk); cmd_valid = 0;
        end
    endtask

    task fill_words;
        input integer words;
        integer i;
        begin
            for (i = 0; i < words; i = i + 1) begin
                wr_valid = 1; wr_data = 128'h1122334455667788 + i;
                @(posedge core_clk);
                if (!wr_ready) $fatal(1, "write fill not accepted");
                @(negedge core_clk);
            end
            wr_valid = 0;
        end
    endtask

    task accept_aw;
        begin
            if (!axi_awvalid) $fatal(1, "missing AW");
            axi_awready = 1;
            @(posedge core_clk);
            @(negedge core_clk); axi_awready = 0;
        end
    endtask

    task accept_ar;
        begin
            if (!axi_arvalid) $fatal(1, "missing AR");
            axi_arready = 1;
            @(posedge core_clk);
            @(negedge core_clk); axi_arready = 0;
        end
    endtask

    task expect_fault;
        input [3:0] code;
        integer guard;
        begin
            guard = 0;
            while (!fault && guard < 80) begin
                @(negedge core_clk); guard = guard + 1;
            end
            if (!fault || !error || error_code !== code || !busy || cmd_ready || done || rd_valid || wr_ready)
                $fatal(1, "fault status mismatch actual=%0d expected=%0d", error_code, code);
            clear_status = 1;
            repeat(3) @(negedge core_clk);
            clear_status = 0;
            if (!fault || !error || error_code !== code || cmd_ready)
                $fatal(1, "fatal error cleared without reset");
            checked_faults = checked_faults + 1;
        end
    endtask

    initial begin
        // 地址通道不接收：超时后仍需维持 VALID 和参数，直到握手或共同复位。
        reset_all; send_command(1, 16); fill_words(1);
        saved_address = axi_awaddr; saved_length = axi_awlen;
        expect_fault(4);
        if (!axi_awvalid || axi_awaddr !== saved_address || axi_awlen !== saved_length)
            $fatal(1, "AW withdrawn/changed after timeout");

        reset_all; send_command(1, 16); fill_words(1); accept_aw;
        expect_fault(4); // 写数据通道没有进展。

        reset_all; send_command(0, 16);
        saved_address = axi_araddr; saved_length = axi_arlen;
        expect_fault(4);
        if (!axi_arvalid || axi_araddr !== saved_address || axi_arlen !== saved_length)
            $fatal(1, "AR withdrawn/changed after timeout");

        reset_all; send_command(0, 16); accept_ar;
        expect_fault(4); // 已接受 AR，但没有返回数据。

        // 使用不跨列的地址，使长度为两拍的写请求确实只有一个原生段。
        reset_all;
        @(negedge core_clk);
        cmd_valid = 1; cmd_write = 1; cmd_addr = 32'h100; cmd_len = 32;
        @(posedge core_clk); @(negedge core_clk); cmd_valid = 0;
        fill_words(2); accept_aw;
        axi_wready = 1; axi_wusero_last = 1;
        expect_fault(5); // 首拍就出现 WLAST。

        reset_all; send_command(1, 16); fill_words(1); accept_aw;
        axi_wready = 1; axi_wusero_last = 0;
        expect_fault(5); // 应为末拍但没有 WLAST。

        reset_all; send_command(1, 16); fill_words(1); accept_aw;
        axi_wready = 1; axi_wusero_last = 1; axi_wusero_id = 4'ha;
        expect_fault(5);

        reset_all;
        @(negedge core_clk);
        cmd_valid = 1; cmd_write = 0; cmd_addr = 32'h100; cmd_len = 32;
        @(posedge core_clk); @(negedge core_clk); cmd_valid = 0;
        accept_ar; axi_rvalid = 1; axi_rlast = 1;
        expect_fault(6); // 首拍就出现 RLAST。

        reset_all; send_command(0, 16); accept_ar;
        axi_rvalid = 1; axi_rlast = 0;
        expect_fault(6);

        reset_all; send_command(0, 16); accept_ar;
        axi_rvalid = 1; axi_rlast = 1; axi_rid = 4'ha;
        expect_fault(6);

        reset_all; send_command(1, 16);
        ddr_init_done = 0;
        expect_fault(7);

        // 上层暂时不送数据，不属于 DDR 停顿，不应触发总线看门狗。
        reset_all; send_command(1, 16);
        repeat(64) begin
            @(negedge core_clk);
            if (fault || error || axi_awvalid) $fatal(1, "host fill pause treated as DDR timeout");
        end
        fill_words(1);
        // 地址和首拍同一个上升沿接收，也必须正确使用预先缓冲的数据。
        axi_awready = 1; axi_wready = 1; axi_wusero_last = 1;
        if (axi_wdata !== 128'h1122334455667788) $fatal(1, "first write data not prepared");
        @(posedge core_clk);
        @(negedge core_clk); axi_awready = 0; axi_wready = 0;
        if (!done || busy || error) $fatal(1, "same-edge AW/W failed");
        fast_commands = fast_commands + 1;

        reset_all; send_command(0, 16);
        axi_arready = 1; axi_rvalid = 1; axi_rlast = 1; axi_rdata = 128'h9988776655443322;
        @(posedge core_clk);
        @(negedge core_clk); axi_arready = 0; axi_rvalid = 0;
        repeat(64) begin
            if (!rd_valid || rd_data !== 128'h9988776655443322 || !rd_last || done || error || fault)
                $fatal(1, "same-edge AR/R or host drain pause failed");
            @(negedge core_clk);
        end
        rd_ready = 1;
        @(posedge core_clk);
        @(negedge core_clk); rd_ready = 0;
        if (!done || busy || error) $fatal(1, "read drain completion failed");
        fast_commands = fast_commands + 1;

        $display("PASS DDR block transfer faults: fatal_cases=%0d same_edge_commands=%0d host_pauses=2",
                 checked_faults, fast_commands);
        $finish;
    end
    initial begin #1000000; $fatal(1, "fault test timeout"); end
endmodule
