`timescale 1ns/1ps
// Simulation-only observer. No force, drive, delay change, or DUT modification.
`define C tb_coremark.dut.u_soc.cpu
`define S tb_coremark.dut.u_soc
module coremark_profile_monitor #(
    parameter [31:0] LIST_PC=0, MATRIX_PC=0, STATE_PC=0
);
    integer run=0, pcfd, statfd, wavefd, overlapfd, j, mask, sample;
    reg active=0;
    reg [63:0] base_cycles,base_instret,base_load,base_data,base_fetch,base_redirect;
    reg [63:0] pc_count[0:8191], overlap[0:15];
    reg [63:0] retired,not_retired;
    integer remaining[0:2];
    reg captured[0:2];
    reg [31:0] entry_pc[0:2];
    wire sample_timer=!tb_coremark.dut.soc_reset && `S.dv && !`S.dw && `S.dr && `S.da==32'h40002000;
    initial begin
        pcfd=$fopen("profile_pc.csv","w");
        statfd=$fopen("profile_counters.csv","w");
        overlapfd=$fopen("profile_overlap.csv","w");
        wavefd=$fopen("pipeline_windows.csv","w");
        $fdisplay(pcfd,"run,pc,retired");
        $fdisplay(statfd,"run,cycles,instret,load_hazard_cycles,data_wait_cycles,fetch_wait_cycles,redirects,no_retire_cycles");
        $fdisplay(overlapfd,"run,mask,cycles");
        $fdisplay(wavefd,"window,offset,cycle,id_valid,id_pc,x_valid,x_pc,m_valid,m_pc,w_valid,w_pc,retire_valid,retire_pc,retire_insn,load_hazard,imem_valid,imem_ready,dmem_valid,dmem_ready,dmem_write,dmem_addr,redirect,redirect_pc");
        entry_pc[0]=LIST_PC; entry_pc[1]=MATRIX_PC; entry_pc[2]=STATE_PC;
        for(j=0;j<3;j=j+1) begin remaining[j]=0; captured[j]=0; end
    end
    always @(posedge tb_coremark.clk) begin
        if(sample_timer) begin
            if(!active) begin
                base_cycles=`C.cycles; base_instret=`C.instret;
                base_load=`C.load_stall_cycles; base_data=`C.data_wait_cycles;
                base_fetch=`C.fetch_wait_cycles; base_redirect=`C.redirect_count;
                retired=0; not_retired=0;
                for(j=0;j<8192;j=j+1) pc_count[j]=0;
                for(j=0;j<16;j=j+1) overlap[j]=0;
                active=1;
            end else begin
                if(retired != `C.instret-base_instret) $fatal(1,"Profiler retire histogram/counter mismatch");
                if(retired+not_retired != `C.cycles-base_cycles) $fatal(1,"Profiler interval boundary mismatch");
                $fdisplay(statfd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,`C.cycles-base_cycles,
                          `C.instret-base_instret,`C.load_stall_cycles-base_load,`C.data_wait_cycles-base_data,
                          `C.fetch_wait_cycles-base_fetch,`C.redirect_count-base_redirect,not_retired);
                for(j=0;j<8192;j=j+1) if(pc_count[j]!=0) $fdisplay(pcfd,"%0d,%08x,%0d",run,j*4,pc_count[j]);
                for(j=0;j<16;j=j+1) $fdisplay(overlapfd,"%0d,%0d,%0d",run,j,overlap[j]);
                $fflush(pcfd); $fflush(statfd); $fflush(overlapfd); $fflush(wavefd);
                active=0; run=run+1;
                if(run==4) begin
                    for(j=0;j<3;j=j+1) if(!captured[j] || remaining[j]!=0) $fatal(1,"Missing complete algorithm waveform window");
                    $display("COREMARK_PROFILE_PASS intervals=4");
                end
            end
        end
        if(active) begin
            mask=0;
            if(`C.load_hazard) mask=mask|1;
            if(`C.dmem_valid && !`C.dmem_ready) mask=mask|2;
            if(`C.imem_valid && !`C.imem_ready) mask=mask|4;
            if(`C.redirect) mask=mask|8;
            overlap[mask]=overlap[mask]+1;
            if(`C.retire_valid && !`C.retire_trap) begin
                if(`C.retire_pc>=32768 || `C.retire_pc[1:0]!=0) $fatal(1,"Profiler PC outside instruction ROM");
                retired=retired+1;
                pc_count[`C.retire_pc>>2]=pc_count[`C.retire_pc>>2]+1;
            end else not_retired=not_retired+1;
            if(run==0) for(sample=0;sample<3;sample=sample+1) begin
                if(!captured[sample] && `C.retire_valid && `C.retire_pc==entry_pc[sample]) begin
                    captured[sample]=1; remaining[sample]=96;
                end
                if(remaining[sample]>0) begin
                    $fdisplay(wavefd,"%0d,%0d,%0d,%0d,%08x,%0d,%08x,%0d,%08x,%0d,%08x,%0d,%08x,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%08x,%0d,%08x",
                        sample,96-remaining[sample],`C.cycles-base_cycles,`C.id_valid,`C.id_pc,
                        `C.x_valid,`C.x_pc,`C.m_valid,`C.m_pc,`C.w_valid,`C.w_pc,
                        `C.retire_valid,`C.retire_pc,`C.retire_insn,`C.load_hazard,
                        `C.imem_valid,`C.imem_ready,`C.dmem_valid,`C.dmem_ready,`C.dmem_write,`C.dmem_addr,
                        `C.redirect,`C.redirect_pc);
                    remaining[sample]=remaining[sample]-1;
                end
            end
        end
    end
endmodule
`undef C
`undef S
