`timescale 1ns/1ps
module tb_rom_lookahead;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,iv=0,dv=0,dw=0;
    reg [31:0] ia=0,da=0,wd=0;
    reg [3:0] ws=0;
    wire ir,ie,dr,de;
    wire [31:0] idata,rdata;
    rv32_soc_memory #(.ROM_FILE("")) dut(.*);
    integer reads=0,data_reads=0,zero_wait=0,last_wait,groups=0,k,n;
    reg [31:0] random_state=32'h6e3b19a5;
    reg [31:0] address;
    function automatic [31:0] pattern(input [31:0] addr);
        pattern=32'hcafe0000 ^ addr ^ (addr<<11);
    endfunction
    task automatic fetch(input [31:0] addr);
        integer waited;
        reg error_expected;
        begin
            @(negedge clk); iv=1; ia=addr; waited=0;
            error_expected=addr>=32768 || addr[1:0]!=0;
            begin: complete
                forever begin
                    @(posedge clk);
                    if(ir) begin
                        if(ie!==error_expected) $fatal(1,"ROM error mismatch %08x",addr);
                        if(idata!==(error_expected?32'b0:pattern(addr))) $fatal(1,"ROM data/tag mismatch %08x %08x",addr,idata);
                        disable complete;
                    end
                    waited=waited+1;
                    if(waited>3) $fatal(1,"ROM read timed out");
                end
            end
            last_wait=waited; reads=reads+1;
            if(waited==0) zero_wait=zero_wait+1;
        end
    endtask
    task automatic group(input string label);
        begin groups=groups+1; $display("LOOKAHEAD_CHECK %s",label); end
    endtask
    initial begin
        #1; for(k=0;k<8192;k=k+1) begin dut.rom[k]=pattern(k*4); dut.ram[k]=32'h13570000^k; end
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        fetch(0); if(last_wait!=1) $fatal(1,"Cold access must synchronously read ROM");
        for(n=1;n<128;n=n+1) begin
            fetch(n*4); if(last_wait!=0) $fatal(1,"Sequential lookahead failed to sustain one word per clock");
        end
        group("cold_miss_and_128_word_stream");
        @(negedge clk); iv=0;
        repeat(7) begin @(posedge clk); if(ir) $fatal(1,"Completion without a request"); end
        fetch(512); if(last_wait!=0) $fatal(1,"Lookahead lost during idle");
        group("idle_preserves_tag_and_no_spurious_completion");
        fetch(32'h1000); if(last_wait!=1) $fatal(1,"Mismatched tag accepted");
        fetch(32'h18); if(last_wait!=1) $fatal(1,"Redirect mismatch accepted");
        fetch(32'h1c); if(last_wait!=0) $fatal(1,"New stream did not recover");
        group("jump_discards_wrong_lookahead");
        fetch(32764); fetch(0); // unrequested out-of-range lookahead must not poison address zero
        fetch(32764); fetch(32768); fetch(32772);
        fetch(2); fetch(32766); fetch(32'h20000000); fetch(32'hfffffffc); fetch(0);
        group("boundary_misalignment_fault_tag_and_address_wrap");
        @(negedge clk); iv=1; ia=32'h2340;
        @(posedge clk); if(ir) $fatal(1,"Unexpected stale tag hit");
        @(negedge clk); rst=1; iv=0;
        repeat(2) @(posedge clk);
        @(negedge clk); rst=0;
        fetch(32'h2340); if(last_wait!=1) $fatal(1,"Reset did not cancel pending/cached word");
        group("reset_cancels_pending_read");
        for(n=0;n<2048;n=n+1) begin
            random_state=random_state^(random_state<<13);
            random_state=random_state^(random_state>>17);
            random_state=random_state^(random_state<<5);
            if(n%2==0) address=ia+4;
            else if(n%13==0) address=random_state;
            else address=random_state & 32'h7ffc;
            fetch(address);
        end
        group("2048_deterministic_random_and_sequential_requests");
        fork
            begin
                for(integer q=0;q<128;q=q+1) fetch(32'h2000+q*4);
                @(negedge clk); iv=0;
            end
            begin
                for(integer d=0;d<64;d=d+1) begin
                    @(negedge clk); dv=1; dw=0; da=(d%2==0)?d*4:32'h20000000+d*4;
                    begin: data_complete
                        forever begin
                            @(posedge clk);
                            if(dr) begin
                                if(de || rdata!==((d%2==0)?pattern(d*4):(32'h13570000^d)))
                                    $fatal(1,"Concurrent instruction/data ROM or RAM mismatch");
                                data_reads=data_reads+1; disable data_complete;
                            end
                        end
                    end
                    @(negedge clk); dv=0;
                end
            end
        join
        group("independent_data_rom_ram_port");
        $display("ROM_LOOKAHEAD_PASS groups=%0d fetches=%0d data_reads=%0d zero_wait=%0d",groups,reads,data_reads,zero_wait);
        $finish;
    end
    initial begin #1000000; $fatal(1,"ROM lookahead global timeout"); end
endmodule
