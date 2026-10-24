`timescale 1ns/1ps

// 联合用户的 DDR 行为模型验证实际数据搬运。
// 测试向量由 Python 维护独立的“线性字节地址”参考内存后生成，
// 包含不连续地址、部分覆盖、跨列以及接近 DDR 容量上界的访问。
module TB_ddr_block_transfer;
    reg ref_clk = 0;
    always #20 ref_clk = ~ref_clk;
    wire core_clk;
    reg rst_n = 0;
    wire ddr_init_done;
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
    wire axi_awready, axi_arready, axi_wready, axi_wusero_last;
    wire [3:0] axi_wusero_id, axi_rid;
    wire [127:0] axi_wdata, axi_rdata;
    wire [15:0] axi_wstrb;
    wire axi_rlast, axi_rvalid;

    ddr_block_transfer #(.TIMEOUT_CYCLES(8192), .AXI_ID(4'h5)) dut (.*);
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

    reg [95:0] commands [0:2047];
    reg [127:0] vectors [0:32767];
    integer job_count, job, n, checked_words = 0, checked_commands = 0;
    integer aw_count = 0, ar_count = 0, invalid_count = 0;
    integer expected_remaining = 0, expected_segment, native_write_index = 0;
    integer current_vector = 0;
    reg [31:0] expected_cursor;
    reg check_bus = 0, current_write = 0, busy_pulse_tested = 0;
    reg [127:0] held_data;
    reg held_last;

    // 独立检查原生地址与分段长度，不能只靠“同地址写回读回”判断换算正确。
    always @(posedge core_clk) begin
        if (rst_n) begin
            if (done && (busy || error)) $fatal(1, "done/status conflict");
            if (cmd_ready && busy) $fatal(1, "ready while busy");
            if (axi_awvalid && axi_awready) begin
                aw_count = aw_count + 1;
                if (check_bus) begin
                    expected_segment = 2048 - (expected_cursor % 2048);
                    if (expected_segment > expected_remaining) expected_segment = expected_remaining;
                    if (!current_write || expected_remaining <= 0 ||
                        axi_awaddr !== (expected_cursor >> 1) ||
                        axi_awlen !== (expected_segment / 16 - 1) ||
                        axi_awuser_id !== 4'h5 || axi_awuser_ap !== 1'b0)
                        $fatal(1, "AW mapping/split mismatch byte=%h native=%h len=%d", expected_cursor, axi_awaddr, axi_awlen);
                    expected_cursor = expected_cursor + expected_segment;
                    expected_remaining = expected_remaining - expected_segment;
                end
            end
            if (axi_arvalid && axi_arready) begin
                ar_count = ar_count + 1;
                if (check_bus) begin
                    expected_segment = 2048 - (expected_cursor % 2048);
                    if (expected_segment > expected_remaining) expected_segment = expected_remaining;
                    if (current_write || expected_remaining <= 0 ||
                        axi_araddr !== (expected_cursor >> 1) ||
                        axi_arlen !== (expected_segment / 16 - 1) ||
                        axi_aruser_id !== 4'h5 || axi_aruser_ap !== 1'b0)
                        $fatal(1, "AR mapping/split mismatch byte=%h native=%h len=%d", expected_cursor, axi_araddr, axi_arlen);
                    expected_cursor = expected_cursor + expected_segment;
                    expected_remaining = expected_remaining - expected_segment;
                end
            end
            if (check_bus && current_write && axi_wready) begin
                if (axi_wstrb !== 16'hffff || axi_wdata !== vectors[current_vector + native_write_index])
                    $fatal(1, "native write data mismatch word=%0d", native_write_index);
                native_write_index = native_write_index + 1;
            end
        end
    end

    task send_command;
        input direction;
        input [31:0] address, length;
        begin
            @(negedge core_clk);
            cmd_valid = 1; cmd_write = direction; cmd_addr = address; cmd_len = length;
            do @(posedge core_clk); while (!cmd_ready);
            @(negedge core_clk);
            cmd_valid = 0;
            // 命令接收后立即改动输入，检查执行过程确实使用已锁存的配置。
            cmd_write = !direction; cmd_addr = 32'hdeadbeef; cmd_len = 32'hffffffff;
        end
    endtask

    task run_job;
        input integer index;
        integer words, k, pause;
        begin
            current_write = commands[index][64];
            expected_cursor = commands[index][63:32];
            expected_remaining = commands[index][31:0];
            words = expected_remaining / 16;
            current_vector = index * 16; native_write_index = 0; check_bus = 1;
            send_command(current_write, expected_cursor, expected_remaining);
            if (done || error || !busy) $fatal(1, "command acceptance/status");
            if (current_write) begin
                for (k = 0; k < words; k = k + 1) begin
                    repeat(k % 3) @(negedge core_clk);
                    wr_valid = 1; wr_data = vectors[current_vector + k];
                    do @(posedge core_clk); while (!wr_ready);
                    @(negedge core_clk); wr_valid = 0;
                    if (!busy_pulse_tested && words > 1 && k == 0) begin
                        // 忙时的一拍新命令不应被接收，也不能覆盖正在执行的地址。
                        cmd_valid = 1; cmd_write = 0; cmd_addr = 32'h10000; cmd_len = 16;
                        @(posedge core_clk);
                        if (cmd_ready) $fatal(1, "accepted busy command");
                        @(negedge core_clk); cmd_valid = 0; busy_pulse_tested = 1;
                    end
                end
            end else begin
                for (k = 0; k < words; k = k + 1) begin
                    while (!rd_valid) begin
                        if (error) $fatal(1, "read error code=%0d", error_code);
                        @(negedge core_clk);
                    end
                    held_data = rd_data; held_last = rd_last;
                    pause = (k % 3) + 1;
                    repeat(pause) begin
                        @(negedge core_clk);
                        if (!rd_valid || rd_data !== held_data || rd_last !== held_last || done)
                            $fatal(1, "read data changed under backpressure");
                    end
                    rd_ready = 1;
                    @(posedge core_clk);
                    if (!rd_valid || rd_data !== vectors[current_vector + k] || rd_last !== (k == words - 1))
                        $fatal(1, "read mismatch job=%0d word=%0d got=%h expected=%h", index, k, rd_data, vectors[current_vector + k]);
                    checked_words = checked_words + 1;
                    @(negedge core_clk); rd_ready = 0;
                end
            end
            while (!done && !error) @(negedge core_clk);
            if (error || fault || busy || expected_remaining != 0)
                $fatal(1, "command completion error job=%0d code=%0d remaining=%0d", index, error_code, expected_remaining);
            if (current_write && native_write_index != words) $fatal(1, "wrong write beat count");
            check_bus = 0;
            repeat(3) begin
                @(negedge core_clk);
                if (!done || busy || error) $fatal(1, "done is not sticky");
            end
            checked_commands = checked_commands + 1;
        end
    endtask

    task bad_command;
        input [31:0] address, length;
        input [3:0] code;
        integer previous_aw, previous_ar;
        begin
            previous_aw = aw_count; previous_ar = ar_count;
            send_command(1'b0, address, length);
            if (!error || error_code !== code || busy || done || fault || !cmd_ready)
                $fatal(1, "invalid-command status code=%0d expected=%0d", error_code, code);
            repeat(3) @(negedge core_clk);
            if (aw_count != previous_aw || ar_count != previous_ar)
                $fatal(1, "invalid command accessed DDR");
            clear_status = 1;
            @(negedge core_clk); clear_status = 0;
            if (error || done || error_code != 0) $fatal(1, "clear_status failed");
            invalid_count = invalid_count + 1;
        end
    endtask

    task reset_system;
        begin
            @(negedge core_clk);
            rst_n = 0; cmd_valid = 0; wr_valid = 0; rd_ready = 0; clear_status = 0; check_bus = 0;
            repeat(4) @(negedge ref_clk);
            rst_n = 1;
            while (!ddr_init_done) begin
                @(negedge core_clk);
                if ((!ddr_init_done && cmd_ready) || busy || done || error || axi_awvalid || axi_arvalid)
                    $fatal(1, "reset/init gating failed");
            end
            @(negedge core_clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("JOBS=%d", job_count)) $fatal(1, "missing JOBS");
        if (job_count < 2 || job_count > 2048) $fatal(1, "invalid JOBS");
        $readmemh("commands.mem", commands, 0, job_count - 1);
        $readmemh("data.mem", vectors, 0, job_count * 16 - 1);
        reset_system;
        bad_command(0, 0, 1);
        bad_command(0, 272, 1);
        bad_command(1, 16, 2);
        bad_command(0, 15, 2);
        bad_command(32'h20000000, 16, 3);
        bad_command(32'h1ffffff0, 32, 3);
        bad_command(32'hfffffff0, 256, 3);
        for (job = 0; job < job_count; job = job + 1) run_job(job);

        // 收集写数据期间复位：不能提前发 AW，也不能泄漏半块旧缓冲。
        send_command(1'b1, 32'h18000, 256);
        wr_valid = 1; wr_data = 128'h1234;
        @(posedge core_clk);
        @(negedge core_clk); wr_valid = 0;
        if (axi_awvalid || !busy) $fatal(1, "AW before complete write block");
        reset_system; run_job(0); run_job(1);

        // 原生写进行中复位：允许部分数据已落 DDR，恢复后重新写入再核对。
        send_command(1'b1, 32'h18000, 256);
        for (n = 0; n < 16; n = n + 1) begin
            wr_valid = 1; wr_data = vectors[n];
            @(posedge core_clk);
            @(negedge core_clk);
        end
        wr_valid = 0;
        do @(posedge core_clk); while (!axi_wready);
        reset_system; run_job(0); run_job(1);

        // 原生读地址被接收后复位，排除旧命令返回污染下一次操作。
        send_command(1'b0, 32'h100, 256);
        do @(posedge core_clk); while (!(axi_arvalid && axi_arready));
        reset_system; run_job(0); run_job(1);

        // 上层尚未取走整块结果时复位，旧输出必须失效。
        send_command(1'b0, 32'h100, 256);
        wait(rd_valid);
        reset_system; run_job(0); run_job(1);

        $display("PASS DDR block transfer: commands=%0d read_words=%0d invalid=%0d AW=%0d AR=%0d resets=4",
                 checked_commands, checked_words, invalid_count, aw_count, ar_count);
        $finish;
    end
    initial begin #100000000; $fatal(1, "global timeout"); end
endmodule
