`timescale 1ns/1ps
`define C tb_coremark.dut.u_soc.cpu
`define S tb_coremark.dut.u_soc
module evolve_profile_monitor;
    reg active=0;integer run=0,fd,pfd,k,index;
    reg [63:0] counters[0:15];
    integer pc_retired[0:8191],pc_mwait[0:8191],pc_branchmiss[0:8191],pc_pairtype[0:8191];
    wire sample=!tb_coremark.dut.soc_reset && `S.fabric.pv && !`S.fabric.pw && `S.fabric.p_ready && `S.fabric.pa==32'h40002000;
    task retirement(input [31:0] insn,input [31:0] pc);
        begin
            if(pc<32768)pc_retired[pc>>2]=pc_retired[pc>>2]+1;
            if(insn[6:0]==7'h33 && insn[31:25]==1)begin
                if(insn[14])counters[3]=counters[3]+1;else counters[2]=counters[2]+1;
            end
            if(insn[6:0]==7'h03)counters[4]=counters[4]+1;
            if(insn[6:0]==7'h23)counters[5]=counters[5]+1;
        end
    endtask
    initial begin
        fd=$fopen("evolve_metrics.csv","w");pfd=$fopen("pc_metrics.csv","w");
        $fdisplay(fd,"run,cycles,retired,mul_retired,divrem_retired,loads,stores,mul_wait,div_wait,store_wait,load_wait,other_data_wait,pair_branch,pair_memory,pair_multiply,pair_raw_alu,pair_other");
        $fdisplay(pfd,"run,pc,retired,md_wait,branch_misses,secondary_type_reject");
    end
    always @(posedge tb_coremark.clk)begin
        if(sample)begin
            if(!active)begin
                for(k=0;k<16;k=k+1)counters[k]=0;
                for(k=0;k<8192;k=k+1)begin pc_retired[k]=0;pc_mwait[k]=0;pc_branchmiss[k]=0;pc_pairtype[k]=0;end
                active=1;
            end else begin
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,counters[0],counters[1],counters[2],counters[3],counters[4],counters[5],counters[6],counters[7],counters[8],counters[9],counters[10],counters[11],counters[12],counters[13],counters[14],counters[15]);
                for(k=0;k<8192;k=k+1)if(pc_retired[k] || pc_mwait[k] || pc_branchmiss[k] || pc_pairtype[k])
                    $fdisplay(pfd,"%0d,%0d,%0d,%0d,%0d,%0d",run,k*4,pc_retired[k],pc_mwait[k],pc_branchmiss[k],pc_pairtype[k]);
                $fflush(fd);$fflush(pfd);active=0;run=run+1;
                if(run==4)$display("EVOLVE_PROFILE_PASS runs=4");
            end
        end
        if(active)begin
            counters[0]=counters[0]+1;
            if(`C.retire_valid && !`C.retire_trap)begin counters[1]=counters[1]+1;retirement(`C.retire_insn,`C.retire_pc);end
            if(`C.retire2_valid)begin counters[1]=counters[1]+1;retirement(`C.retire2_insn,`C.retire2_pc);end
            if(`C.x_valid && `C.any_mop && !`C.md_valid)begin
                if(`C.x2_mop?`C.x2_insn[14]:`C.x_f3[2])counters[7]=counters[7]+1;else counters[6]=counters[6]+1;
                if(`C.x2_mop)begin
                    if(`C.x2_pc<32768)pc_mwait[`C.x2_pc>>2]=pc_mwait[`C.x2_pc>>2]+1;
                end else if(`C.x_pc<32768)pc_mwait[`C.x_pc>>2]=pc_mwait[`C.x_pc>>2]+1;
            end
            if(`C.dmem_valid && !`C.dmem_ready)begin
                if(`C.dmem_write)counters[8]=counters[8]+1;
                else if(`C.m_load || (`C.memory_in_second && `C.m2_load))counters[9]=counters[9]+1;
                else counters[10]=counters[10]+1;
            end
            if(`C.retire_valid && !`C.retire_trap && `C.w_prediction_wrong && `C.w_control && `C.retire_pc<32768)
                pc_branchmiss[`C.retire_pc>>2]=pc_branchmiss[`C.retire_pc>>2]+1;
            if(`C.retire2_valid && `C.w2_wrong && `C.w2_control && `C.retire2_pc<32768)
                pc_branchmiss[`C.retire2_pc>>2]=pc_branchmiss[`C.retire2_pc>>2]+1;
            if(`C.id_valid && `C.id2_valid && `C.id_ready && !`C.issue_pair)begin
                if(`C.id2_pc<32768)pc_pairtype[`C.id2_pc>>2]=pc_pairtype[`C.id2_pc>>2]+1;
                if(`C.id2_insn[6:0]==7'h63 || `C.id2_insn[6:0]==7'h6f || `C.id2_insn[6:0]==7'h67)counters[11]=counters[11]+1;
                else if(`C.id2_insn[6:0]==7'h03 || `C.id2_insn[6:0]==7'h23)counters[12]=counters[12]+1;
                else if(`C.id2_insn[6:0]==7'h33 && `C.id2_insn[31:25]==1)counters[13]=counters[13]+1;
                else if(`C.primary_pair_type && `C.secondary_pair_type && `C.pair_raw)counters[14]=counters[14]+1;
                else counters[15]=counters[15]+1;
            end
        end
    end
endmodule
`undef C
`undef S
