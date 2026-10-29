`timescale 1ns/1ps
module TB_acore_compare;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    integer cycles = 0, trace_file, r, stop_pc, i;
    reg done0 = 0, done1 = 0;
    wire we0, we1, err0, err1;
    wire [31:0] addr0, addr1, data0, data1;
    Acore #(.ENABLE_DUAL(0)) single_core (
        .clk(clk), .rst_n(rst_n), .timer_irq(1'b0), .dev_we(we0), .dev_re(), .bus_err(err0),
        .dev_addr_wr(addr0), .dev_addr_rd(), .dev_wdata(data0), .dev_size(), .dev_rdata(32'b0)
    );
    Acore #(.ENABLE_DUAL(1)) dual_core (
        .clk(clk), .rst_n(rst_n), .timer_irq(1'b0), .dev_we(we1), .dev_re(), .bus_err(err1),
        .dev_addr_wr(addr1), .dev_addr_rd(), .dev_wdata(data1), .dev_size(), .dev_rdata(32'b0)
    );
    initial begin
        r = $value$plusargs("stop_pc=%h", stop_pc);
        if (!r) $fatal(1, "Missing stop PC");
        trace_file = $fopen("build/acore-dual/trace.txt", "w");
        repeat (4) @(negedge clk);
        rst_n = 1;
    end
    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (cycles > 200000) $fatal(1, "Comparison timed out");
        if (err0 || err1) $fatal(1, "Bus error");
        if ((we0 && addr0 != 32'h30000) || (we1 && addr1 != 32'h30000))
            $fatal(1, "Wrong-path MMIO store");
        if (single_core.retire_a_MEM && !done0) begin
            $fdisplay(trace_file, "0 %h %h %h %h", single_core.retire_pc_MEM,
                single_core.instruction_MEM,
                single_core.wr_en_WB ? single_core.wr_addr_WB : 5'd0,
                (single_core.wr_en_WB && single_core.wr_addr_WB != 0) ? single_core.wr_data_WB : 32'b0);
            if (single_core.retire_pc_MEM == stop_pc) done0 = 1;
        end
        if (dual_core.retire_a_MEM && !done1) begin
            $fdisplay(trace_file, "1 %h %h %h %h", dual_core.retire_pc_MEM,
                dual_core.instruction_MEM,
                dual_core.wr_en_WB ? dual_core.wr_addr_WB : 5'd0,
                (dual_core.wr_en_WB && dual_core.wr_addr_WB != 0) ? dual_core.wr_data_WB : 32'b0);
            if (dual_core.retire_pc_MEM == stop_pc) done1 = 1;
        end
        if (dual_core.b_valid_MEM && !done1)
            $fdisplay(trace_file, "1 %h %h %h %h", dual_core.b_pc_MEM,
                dual_core.b_instruction_MEM, dual_core.b_rd_MEM,
                dual_core.b_rd_MEM != 0 ? dual_core.b_result_MEM : 32'b0);
        if (done0 && done1) begin
            for (i = 0; i < 65536; i = i + 1)
                if (single_core.u_memory.u_memory_core.memory[i] !== dual_core.u_memory.u_memory_core.memory[i])
                    $fatal(1, "Final RAM mismatch at byte %h", i);
            if (dual_core.secondary_count == 0) $fatal(1, "No secondary retirement");
            $fclose(trace_file);
            $display("PASS Acore comparison: %0d cycles, %0d secondary instructions", cycles, dual_core.secondary_count);
            $finish;
        end
    end
endmodule
