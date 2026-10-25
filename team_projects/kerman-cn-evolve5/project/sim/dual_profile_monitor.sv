`timescale 1ns/1ps
`define C tb_coremark.dut.u_soc.cpu
`define S tb_coremark.dut.u_soc
module dual_profile_monitor;
    reg active=0;integer fd,run=0,k;
    reg [63:0] events[0:10],start_instret;
    reg [31:0] start_issued,start_retired;
    wire sample=!tb_coremark.dut.soc_reset && `S.fabric.pv && !`S.fabric.pw && `S.fabric.p_ready && `S.fabric.pa==32'h40002000;
    initial begin
        fd=$fopen("dual_metrics.csv","w");
        $fdisplay(fd,"run,cycles,slot0_retired,slot1_retired,pairs_issued,two_available_decisions,pair_raw,pair_waw,pair_type_or_fault,icache_second_responses,load_blocked,data_wait");
    end
    always @(posedge tb_coremark.clk) begin
        if(sample) begin
            if(!active) begin
                for(k=0;k<11;k=k+1) events[k]=0;
                start_instret=`C.instret;start_issued=`C.issue_pairs;start_retired=`C.retired_pairs;active=1;
            end else begin
                if(events[1]+events[2]!==`C.instret-start_instret || events[2]!==`C.retired_pairs-start_retired || events[3]!==`C.issue_pairs-start_issued)
                    $fatal(1,"Dual retirement/issue counters disagree with ordered event observations");
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,events[0],events[1],events[2],events[3],events[4],events[5],events[6],events[7],events[8],events[9],events[10]);
                $fflush(fd);active=0;run=run+1;if(run==4)$display("DUAL_PROFILE_PASS runs=4");
            end
        end
        if(active) begin
            events[0]=events[0]+1;
            if(`C.retire_valid && !`C.retire_trap)events[1]=events[1]+1;
            if(`C.retire2_valid)events[2]=events[2]+1;
            if(`C.id_valid && `C.id_ready && `C.issue_pair)events[3]=events[3]+1;
            if(`C.id_valid && `C.id_ready && `C.id2_valid)begin
                events[4]=events[4]+1;
                if(!`C.primary_pair_type || !`C.secondary_pair_type || `C.id_illegal || `C.id2_illegal || `C.id_fetch_error || `C.id2_fetch_error) events[7]=events[7]+1;
                else if(`C.pair_raw) events[5]=events[5]+1;
                else if(`C.pair_waw) events[6]=events[6]+1;
            end
            if(`C.imem_valid && `C.imem_ready && `C.imem_second_valid)events[8]=events[8]+1;
            if(`C.load_hazard)events[9]=events[9]+1;
            if(`C.dmem_valid && !`C.dmem_ready)events[10]=events[10]+1;
        end
        if(!tb_coremark.dut.soc_reset) begin
            if(`C.retire2_valid && (!`C.retire_valid || `C.retire_trap))$fatal(1,"Younger instruction escaped older trap");
            if(`C.x2_valid && !`C.x_valid || `C.m2_valid && !`C.m_valid || `C.w2_valid && !`C.w_valid)$fatal(1,"Ungrouped secondary pipeline state");
        end
    end
endmodule
`undef C
`undef S
