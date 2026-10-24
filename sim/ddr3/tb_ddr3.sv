`timescale 1ns/1ps
// Latency-independent black-box tests. This same bench can drive the vendor IP.
module tb_ddr3;
    reg ref_clk = 0, resetn = 0;
    always #20 ref_clk = ~ref_clk;
    wire core_clk, ddr_init_done;
    reg [27:0] axi_awaddr = 0, axi_araddr = 0;
    reg axi_awuser_ap = 0, axi_aruser_ap = 0;
    reg [3:0] axi_awuser_id = 0, axi_aruser_id = 0;
    reg [3:0] axi_awlen = 0, axi_arlen = 0;
    reg axi_awvalid = 0, axi_arvalid = 0;
    wire axi_awready, axi_arready, axi_wready, axi_wusero_last;
    wire [3:0] axi_wusero_id, axi_rid;
    reg [127:0] axi_wdata = 0;
    reg [15:0] axi_wstrb = 16'hffff;
    wire [127:0] axi_rdata;
    wire axi_rvalid, axi_rlast;
    reg apb_rst_n = 0, apb_sel = 0, apb_enable = 0, apb_write = 0;
    reg [7:0] apb_addr = 0;
    reg [15:0] apb_wdata = 0;
    wire apb_ready;
    wire [15:0] apb_rdata;
    wire mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_ras_n, mem_cas_n, mem_we_n, mem_odt;
    wire [14:0] mem_a;
    wire [2:0] mem_ba;
    wire [1:0] mem_dqs, mem_dqs_n, mem_dm;
    wire [15:0] mem_dq;
    integer checks = 0, beat, length, lane, iteration;
    reg [127:0] expected, mask_expected;
    reg [15:0] status;

    ddr3 dut (
        .ref_clk(ref_clk), .resetn(resetn), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id), .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(ref_clk), .apb_rst_n(apb_rst_n), .apb_sel(apb_sel), .apb_enable(apb_enable),
        .apb_addr(apb_addr), .apb_write(apb_write), .apb_wdata(apb_wdata),
        .apb_ready(apb_ready), .apb_rdata(apb_rdata),
        .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n), .mem_cke(mem_cke),
        .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n), .mem_odt(mem_odt),
        .mem_a(mem_a), .mem_ba(mem_ba), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq), .mem_dm(mem_dm),
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1),
        .dbg_gpll_scan_rst(1'b0), .samp_position_dyn_adj(1'b0),
        .init_samp_position_even(16'd0), .init_samp_position_odd(16'd0),
        .wrcal_position_dyn_adj(1'b0), .init_wrcal_position(16'd0),
        .force_read_clk_ctrl(1'b0), .init_slip_step(8'd0), .init_read_clk_ctrl(6'd0),
        .debug_cpd_offset_adj(1'b0), .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'd0),
        .ck_dly_en(1'b0), .init_ck_dly_step(8'd0)
    );

`ifdef DDR3_VENDOR_ORACLE
    reg grs_n = 0;
    initial #5 grs_n = 1;
    GTP_GRS GRS_INST(.GRS_N(grs_n));
    ddr3_model #(.DEBUG(0)) chip (
        .rst_n(mem_rst_n), .ck(mem_ck), .ck_n(mem_ck_n), .cke(mem_cke), .cs_n(1'b0),
        .ras_n(mem_ras_n), .cas_n(mem_cas_n), .we_n(mem_we_n), .odt(mem_odt),
        .addr(mem_a), .ba(mem_ba), .dq(mem_dq), .dqs(mem_dqs), .dqs_n(mem_dqs_n),
        .dm_tdqs(mem_dm), .tdqs_n()
    );
`endif

    function automatic [127:0] pattern(input integer number);
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1)
                pattern[j*8 +: 8] = 8'((number * 37) ^ (j * 19) ^ (number >> 4));
        end
    endfunction

    task automatic send_aw(input [27:0] address, input integer count, input [3:0] id);
        begin
            @(negedge core_clk);
            axi_awaddr = address; axi_awlen = 4'(count - 1); axi_awuser_id = id;
            axi_awvalid = 1;
            do @(posedge core_clk); while (!axi_awready);
            @(negedge core_clk); axi_awvalid = 0;
        end
    endtask

    task automatic send_ar(input [27:0] address, input integer count, input [3:0] id);
        begin
            @(negedge core_clk);
            axi_araddr = address; axi_arlen = 4'(count - 1); axi_aruser_id = id;
            axi_arvalid = 1;
            do @(posedge core_clk); while (!axi_arready);
            @(negedge core_clk); axi_arvalid = 0;
        end
    endtask

    task automatic write_data(input integer count, input integer number, input [3:0] id,
                              input bit last_on_end = 1);
        integer j;
        begin
            for (j = 0; j < count; j = j + 1) begin
                @(negedge core_clk); axi_wdata = pattern(number + j);
                do @(posedge core_clk); while (!axi_wready);
                if (axi_wusero_id !== id || axi_wusero_last !== (last_on_end && j == count - 1))
                    $fatal(1, "W id/last mismatch beat=%0d id=%h last=%b", j, axi_wusero_id, axi_wusero_last);
                checks = checks + 1;
            end
        end
    endtask

    task automatic write_burst(input [27:0] address, input integer count,
                               input integer number, input [3:0] id);
        begin
            // Prepare beat zero before AW: even an immediate pull is legal.
            axi_wdata = pattern(number);
            fork
                send_aw(address, count, id);
                write_data(count, number, id);
            join
        end
    endtask

    task automatic receive_one(input [127:0] data, input [3:0] id, input bit last);
        begin
            do @(posedge core_clk); while (!axi_rvalid);
            if (axi_rdata !== data || axi_rid !== id || axi_rlast !== last)
                $fatal(1, "R mismatch got=%h expected=%h id=%h/%h last=%b/%b",
                       axi_rdata, data, axi_rid, id, axi_rlast, last);
            checks = checks + 1;
        end
    endtask

    task automatic read_burst(input [27:0] address, input integer count,
                              input integer number, input [3:0] id);
        integer j;
        begin
            fork
                send_ar(address, count, id);
                begin
                    for (j = 0; j < count; j = j + 1)
                        receive_one(pattern(number + j), id, j == count - 1);
                end
            join
        end
    endtask

    task automatic apb_access(input bit wr, input [7:0] address,
                              input [15:0] data, output [15:0] result);
        begin
            @(negedge ref_clk);
            apb_sel = 1; apb_enable = 0; apb_write = wr; apb_addr = address; apb_wdata = data;
            @(negedge ref_clk); apb_enable = 1;
            do @(posedge ref_clk); while (!apb_ready);
            result = apb_rdata;
            @(negedge ref_clk); apb_sel = 0; apb_enable = 0;
        end
    endtask

    initial begin
        // A reset assertion edge is required by both the vendor and the model.
        #1 resetn = 1; #9 resetn = 0;
        #70 resetn = 1; apb_rst_n = 1;
        wait(ddr_init_done);
        repeat (4) @(negedge core_clk);
        if ($test$plusargs("test_unaligned")) begin
            send_aw(28'h1, 1, 0);
            $fatal(1, "UNREACHED unaligned check");
        end
        if ($test$plusargs("test_unstable_aw")) begin
            resetn = 0;
            @(negedge core_clk); resetn = 1; axi_awvalid = 1; axi_awaddr = 0;
            @(negedge core_clk); axi_awaddr = 8;
            repeat (3) @(negedge core_clk);
            $fatal(1, "UNREACHED unstable check");
        end
        if ($test$plusargs("test_sparse") || $test$plusargs("test_full")) begin
            // Compile this case with DDR3_MODEL_SLOTS=4: force hash collisions.
            for (integer k = 0; k < 4; k = k + 1)
                write_burst(28'(k * 1024), 1, 50000 + k, 4'(k));
            for (integer k = 0; k < 4; k = k + 1)
                read_burst(28'(k * 1024), 1, 50000 + k, 4'(k));
            if ($test$plusargs("test_full")) begin
                write_burst(28'h8000000, 1, 60000, 6);
                $fatal(1, "UNREACHED table full check");
            end
            // A full table can still read an untouched location without allocation.
            fork
                send_ar(28'h8000000, 1, 8);
                receive_one(128'bx, 8, 1);
            join
            axi_wstrb = 0; write_burst(28'h8000000, 1, 60000, 7);
            fork
                send_ar(28'h8000000, 1, 9);
                receive_one(128'bx, 9, 1);
            join
            $display("PASS tb_ddr3 sparse checks=%0d", checks);
            $finish;
        end
        // Every length, every ID, AP on/off, and nonuniform data in all bytes.
        for (length = 1; length <= 16; length = length + 1) begin
            axi_awuser_ap = length[0]; axi_aruser_ap = !length[0];
            write_burst(28'(length * 1024), length, length * 100, 4'(length - 1));
            read_burst(28'(length * 1024), length, length * 100, 4'(16 - length));
        end
        // Address unit: next 128-bit word is native +8, not +16.
        write_burst(28'h00400, 2, 7000, 3);
        read_burst(28'h00408, 1, 7001, 11);
        // High bank/row addresses must not alias a reduced simulation window.
        write_burst(28'h8000400, 1, 8000, 4);
        // These two addresses hash to the same default table slot.
        write_burst(28'h4400, 1, 8100, 5);
        read_burst(28'h4400, 1, 8100, 6);
        read_burst(28'h00400, 1, 7000, 2);
        read_burst(28'h8000400, 1, 8000, 14);
        // Column wrapping retains row and bank: 0x3f8 -> 0, not 0x400.
        write_burst(28'h3f8, 2, 9000, 15);
        read_burst(28'h3f8, 1, 9000, 1);
        read_burst(28'h0, 1, 9001, 2);
        read_burst(28'h400, 1, 7000, 3);
        // One enabled byte at a time, with every other byte preserved.
        write_burst(28'h9000, 1, 10000, 5); mask_expected = pattern(10000);
        for (lane = 0; lane < 16; lane = lane + 1) begin
            axi_wstrb = 16'h1 << lane;
            write_burst(28'h9000, 1, 10001 + lane, 6);
            expected = pattern(10001 + lane);
            mask_expected[lane*8 +: 8] = expected[lane*8 +: 8];
            fork
                send_ar(28'h9000, 1, 7);
                receive_one(mask_expected, 7, 1);
            join
        end
        axi_wstrb = 0; write_burst(28'h9000, 1, 12345, 8);
        fork
            send_ar(28'h9000, 1, 9);
            receive_one(mask_expected, 9, 1);
        join
        axi_wstrb = 16'hffff;
        // Queues: more than QUEUE_DEPTH requests, with independent W/R streams.
        fork
            begin
                for (integer k = 0; k < 40; k = k + 1)
                    send_aw(28'(32768 + 8*k), 1, 4'(k));
            end
            begin
                for (integer k = 0; k < 40; k = k + 1)
                    write_data(1, 20000 + k, 4'(k));
            end
        join
        fork
            begin
                for (integer k = 0; k < 40; k = k + 1)
                    send_ar(28'(32768 + 8*k), 1, 4'(k+3));
            end
            begin
                for (integer k = 0; k < 40; k = k + 1)
                    receive_one(pattern(20000+k), 4'(k+3), 1);
            end
        join
        // Concurrent read/write on different words, each channel keeps its IDs.
        fork
            write_burst(28'hc000, 16, 30000, 12);
            read_burst(28'h8000, 16, 20000, 4);
        join
        read_burst(28'hc000, 16, 30000, 13);
`ifndef DDR3_VENDOR_ORACLE
        // Functional APB subset and explicit low-power hold/resume.
        apb_access(0, 5, 0, status);
        if (status !== 0) $fatal(1, "APB initial mode mismatch");
        apb_access(1, 4, 16'h8001, status);
        repeat (8) @(negedge ref_clk);
        apb_access(0, 5, 0, status);
        if (status !== 1 || axi_awready || axi_arready) $fatal(1, "APB self-refresh mismatch");
        apb_access(1, 4, 16'h0001, status);
        repeat (8) @(negedge ref_clk);
        read_burst(28'hc000, 1, 30000, 0);
        // Reset aborts a partially consumed write; accepted data survives.
        send_aw(28'h10000, 16, 5);
        write_data(3, 40000, 5, 0);
        @(negedge core_clk); resetn = 0; apb_rst_n = 0;
        repeat (4) @(negedge core_clk);
        if (axi_wready || axi_rvalid || axi_awready || axi_arready || ddr_init_done)
            $fatal(1, "Interface active during reset");
        resetn = 1; apb_rst_n = 1;
        wait(ddr_init_done);
        read_burst(28'h10000, 3, 40000, 10);
        read_burst(28'h8000400, 1, 8000, 11);
`endif
        repeat (40) begin
            @(posedge core_clk);
            if (axi_wready || axi_wusero_last || axi_rvalid || axi_rlast)
                $fatal(1, "Unexpected extra data beat");
        end
        $display("PASS tb_ddr3 checks=%0d", checks);
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "DDR3 test timeout");
    end
endmodule
