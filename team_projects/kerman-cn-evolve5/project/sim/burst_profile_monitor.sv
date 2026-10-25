`timescale 1ns/1ps
`define S tb_coremark.dut.u_soc
module burst_profile_monitor;
    reg active=0,busy=0,write_op=0,memory_op=0,cwait=0,rwait=0;
    reg [7:0] remaining;
    reg [77:0] previous_cmd;
    reg [33:0] previous_rsp;
    reg [63:0] cycles,retired,read_commands,write_commands,burst_commands,read_beats,write_responses,cmd_wait,rsp_wait,busy_cycles,both_requests;
    reg [31:0] ih0,im0,dh0,dm0,wh0,wm0;
    integer fd,run=0;
    wire sample=!tb_coremark.dut.soc_reset && `S.fabric.pv && !`S.fabric.pw && `S.fabric.p_ready && `S.fabric.pa==32'h40002000;
    initial begin
        fd=$fopen("bus_metrics.csv","w");
        $fdisplay(fd,"run,cycles,retired,read_commands,write_commands,burst_commands,read_beats,write_responses,command_wait,response_wait,busy_cycles,both_requests,icache_hits,icache_misses,dcache_read_hits,dcache_read_misses,dcache_write_hits,dcache_write_misses");
    end
    always @(posedge tb_coremark.clk) begin
        if(tb_coremark.dut.soc_reset) begin busy=0; cwait=0; rwait=0; active=0; end
        else begin
            if(cwait && (!`S.cv || {`S.ci,`S.cw,`S.ca,`S.cd,`S.cs,`S.cl}!==previous_cmd)) $fatal(1,"Shared command changed while stalled");
            if(rwait && (!`S.rv || {`S.rd,`S.re,`S.rl}!==previous_rsp)) $fatal(1,"Shared response changed while stalled");
            cwait=`S.cv&&!`S.cr; previous_cmd={`S.ci,`S.cw,`S.ca,`S.cd,`S.cs,`S.cl};
            rwait=`S.rv&&!`S.rr; previous_rsp={`S.rd,`S.re,`S.rl};
            if(`S.cv && `S.cr) begin
                if(busy) $fatal(1,"Multiple outstanding shared commands");
                busy=1; remaining=`S.cl; write_op=`S.cw;
                memory_op=`S.ca<32'h8000 || (`S.ca>=32'h20000000 && `S.ca<32'h20008000);
            end
            if(`S.rv && `S.rr) begin
                if(!busy || `S.rl!==(remaining==0)) $fatal(1,"Response routing/length error");
                if(remaining==0) busy=0; else remaining=remaining-1;
            end
            if(sample) begin
                if(!active) begin
                    cycles=0; retired=0; read_commands=0; write_commands=0; burst_commands=0; read_beats=0; write_responses=0;
                    cmd_wait=0; rsp_wait=0; busy_cycles=0; both_requests=0;
                    ih0=`S.i_cache.read_hits; im0=`S.i_cache.read_misses; dh0=`S.d_cache.read_hits; dm0=`S.d_cache.read_misses;
                    wh0=`S.d_cache.write_hits; wm0=`S.d_cache.write_misses; active=1;
                end else begin
                    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,cycles,retired,read_commands,write_commands,burst_commands,read_beats,write_responses,cmd_wait,rsp_wait,busy_cycles,both_requests,
                              `S.i_cache.read_hits-ih0,`S.i_cache.read_misses-im0,`S.d_cache.read_hits-dh0,`S.d_cache.read_misses-dm0,`S.d_cache.write_hits-wh0,`S.d_cache.write_misses-wm0);
                    $fflush(fd); active=0; run=run+1; if(run==4) $display("BURST_PROFILE_PASS runs=4");
                end
            end
            if(active) begin
                cycles=cycles+1;
                if(`S.cpu.retire_valid && !`S.cpu.retire_trap) retired=retired+1;
                if(`S.cpu.retire2_valid) retired=retired+1;
                if(`S.cv && `S.cr && memory_op) begin
                    if(`S.cw) write_commands=write_commands+1; else read_commands=read_commands+1;
                    if(`S.cl!=0) burst_commands=burst_commands+1;
                end
                if(`S.rv && `S.rr && memory_op) begin
                    if(write_op) write_responses=write_responses+1; else read_beats=read_beats+1;
                end
                if(`S.cv && !`S.cr) cmd_wait=cmd_wait+1;
                if(`S.rv && !`S.rr) rsp_wait=rsp_wait+1;
                if(`S.arbiter.state!=0) busy_cycles=busy_cycles+1;
                if(`S.icv && `S.dcv) both_requests=both_requests+1;
            end
        end
    end
endmodule
`undef S
