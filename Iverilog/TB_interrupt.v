`timescale 1ns/1ps
// 真正执行程序的中断回归。只在测试台模拟请求源，CPU/CSR/ROM/RAM 均为真实 RTL。
module TB_interrupt #(
    parameter integer ENABLE_DIV = 0
);
    reg clk = 0;
    reg rst_n = 0;
    reg timer_irq = 0;
    wire dev_we, dev_re, bus_err;
    wire [31:0] dev_addr_wr, dev_addr_rd, dev_wdata;
    wire [1:0] dev_size;
    reg [31:0] dev_rdata = 0;
    always #5 clk = ~clk;

    Acore #(.ENABLE_DIV(ENABLE_DIV)) dut (
        .clk(clk), .rst_n(rst_n), .timer_irq(timer_irq),
        .dev_we(dev_we), .dev_re(dev_re), .bus_err(bus_err),
        .dev_addr_wr(dev_addr_wr), .dev_addr_rd(dev_addr_rd),
        .dev_wdata(dev_wdata), .dev_size(dev_size), .dev_rdata(dev_rdata)
    );

    wire [31:0] gpr [0:31];
    assign gpr[0] = 0;
    genvar g;
    generate for (g = 1; g < 32; g = g + 1) begin : peek
        assign gpr[g] = dut.u_GPR_matrix.g_reg[g].u_Reg.dout;
    end endgenerate
    reg [31:0] saved_gpr [0:31];

    reg [31:0] inject_pc = 0, resume_pc = 0;
    integer expected_irqs = 1, skip_hits = 0, require_stall = 0, min_wait = 0;
    integer expected_stores = 0, expected_prediction = -1, expected_taken = -1;
    integer cycles = 0, hits = 0, accepts = 0, returns = 0, comparisons = 0;
    integer accept_cycle = -100, return_cycle = -100, inject_cycle = 0;
    integer writes_before = 0, writes_after = 0;
    integer i;
    reg injected = 0, acknowledged = 0, snapshot_ready = 0;
    reg [31:0] entry_at_accept;

    initial begin
        if ($value$plusargs("inject=%h", inject_pc)) begin end
        if ($value$plusargs("resume=%h", resume_pc)) begin end
        if ($value$plusargs("irqs=%d", expected_irqs)) begin end
        if ($value$plusargs("skip=%d", skip_hits)) begin end
        if ($value$plusargs("stall=%d", require_stall)) begin end
        if ($value$plusargs("min_wait=%d", min_wait)) begin end
        if ($value$plusargs("stores=%d", expected_stores)) begin end
        if ($value$plusargs("prediction=%d", expected_prediction)) begin end
        if ($value$plusargs("taken=%d", expected_taken)) begin end
        repeat (3) @(negedge clk);
        rst_n = 1;
    end

    // 源信号在下降沿变化；ACK 也由源撤销电平，而不是 CPU 自动清 mip。
    always @(negedge clk) if (rst_n) begin
        if (!injected && expected_irqs != 0 && dut.valid_out_ID && dut.pc_ID == inject_pc) begin
            if (hits == skip_hits) begin
                if (require_stall && !dut.stall)
                    $fatal(1, "request was not injected during the intended stall");
                timer_irq = 1;
                injected = 1;
                inject_cycle = cycles;
            end else if (!dut.stall)
                hits = hits + 1;
        end
        if (acknowledged)
            timer_irq = 0;

        // 接受后两拍，原 EX/MEM/WB 指令均已写回；入口尚未改动 GPR。
        if (cycles == accept_cycle + 2) begin
            for (i = 0; i < 32; i = i + 1)
                saved_gpr[i] = gpr[i];
            snapshot_ready = 1;
        end
        // MRET 后两拍，最后的 sp load 已完成，主程序尚未写回新结果。
        if (cycles == return_cycle + 2) begin
            if (!snapshot_ready) $fatal(1, "no interrupted register snapshot");
            for (i = 0; i < 32; i = i + 1)
                if (gpr[i] !== saved_gpr[i])
                    $fatal(1, "x%0d was not restored: got=%h expected=%h", i, gpr[i], saved_gpr[i]);
            comparisons = comparisons + 1;
        end
    end

    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (cycles > 30000) $fatal(1, "interrupt test timed out pc=%h", dut.pc);
        if (bus_err) $fatal(1, "unmapped CPU access");
        if (dut.stall && (dut.irq_accept || dut.mret_commit || dut.csr_we))
            $fatal(1, "stall incorrectly committed an interrupt, MRET or CSR instruction");
        if (dut.irq_accept && dut.mret_commit)
            $fatal(1, "entry and return committed together");

        if (dev_we && dev_addr_wr == 32'h30010) acknowledged = 1;
        if (dev_we && dev_addr_wr == 32'h30014) writes_before = writes_before + 1;
        if (dev_we && dev_addr_wr == 32'h30018) writes_after = writes_after + 1;
        if (dev_re) dev_rdata <= 0;

        if (dev_we && dev_addr_wr == 32'h30000) begin
            if (dev_wdata != 1) $fatal(1, "firmware failed: exit=%h pc=%h", dev_wdata, dut.pc_ID);
            if (accepts != expected_irqs || returns != expected_irqs || comparisons != expected_irqs)
                $fatal(1, "entry/return/context count mismatch: %0d/%0d/%0d", accepts, returns, comparisons);
            if (writes_before != expected_stores || writes_after != expected_stores)
                $fatal(1, "MMIO stores were lost or repeated: %0d/%0d", writes_before, writes_after);
            $display("PASS interrupt div=%0d entries=%0d returns=%0d contexts=%0d wait=%0d cycles=%0d",
                     ENABLE_DIV, accepts, returns, comparisons, accept_cycle - inject_cycle, cycles);
            $finish;
        end

        if (dut.mret_commit) begin
            returns = returns + 1;
            return_cycle = cycles;
        end
        if (dut.irq_accept) begin
            accepts = accepts + 1;
            accept_cycle = cycles;
            entry_at_accept = dut.irq_entry_pc;
            if (accepts > expected_irqs) $fatal(1, "duplicate interrupt acceptance");
            if (cycles - inject_cycle < min_wait) $fatal(1, "interrupt did not wait for multi-cycle instruction");
            if (dut.irq_resume_pc !== resume_pc)
                $fatal(1, "wrong recovery PC: got=%h expected=%h", dut.irq_resume_pc, resume_pc);
            if (expected_prediction >= 0 && dut.predict_correct !== (expected_prediction != 0))
                $fatal(1, "test did not cover the expected branch prediction state");
            if (expected_taken >= 0 && dut.J_taken !== (expected_taken != 0))
                $fatal(1, "test did not cover the expected actual branch direction");
            #1;
            if (dut.pc !== entry_at_accept || dut.u_CSR.mepc !== resume_pc)
                $fatal(1, "entry redirect/save were not atomic");
            if (dut.valid_out_ID !== 0 || dut.valid_out_IF !== 0)
                $fatal(1, "younger instructions were not flushed");
            if (dut.u_CSR.mcause !== 32'h80000007 || dut.u_CSR.mstatus[3] !== 0)
                $fatal(1, "incorrect trap state");
        end
    end
endmodule
