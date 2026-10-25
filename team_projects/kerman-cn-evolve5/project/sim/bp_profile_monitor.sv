`timescale 1ns/1ps
`define C tb_coremark.dut.u_soc.cpu
`define S tb_coremark.dut.u_soc
module bp_profile_monitor;
    reg active=0;
    integer run=0,fd;
    reg [63:0] base[0:5],observed[0:5];
    integer k;
    task observe(input [31:0] insn,input hit,input pred,input wrong,input taken);
        begin
            if(insn[6:0]==7'h63 || insn[6:0]==7'h6f || insn[6:0]==7'h67)begin
                observed[0]=observed[0]+1;
                if(hit)observed[1]=observed[1]+1;
                if(pred)observed[2]=observed[2]+1;
                if(wrong)observed[3]=observed[3]+1;
                if(insn[6:0]==7'h63)begin
                    observed[4]=observed[4]+1;
                    if(pred!=taken)observed[5]=observed[5]+1;
                end
            end
        end
    endtask
    wire sample_timer=!tb_coremark.dut.soc_reset && `S.fabric.pv && !`S.fabric.pw && `S.fabric.p_ready && `S.fabric.pa==32'h40002000;
    initial begin
        fd=$fopen("bp_stats.csv","w");
        $fdisplay(fd,"run,control_retired,btb_hits,taken_predictions,next_pc_misses,conditional_retired,direction_misses");
    end
    always @(posedge tb_coremark.clk) begin
        if(sample_timer) begin
            if(!active) begin
                base[0]=`C.bp_cf_retired; base[1]=`C.bp_hits; base[2]=`C.bp_taken_predictions;
                base[3]=`C.bp_mispredictions; base[4]=`C.bp_conditional_retired; base[5]=`C.bp_direction_misses;
                for(k=0;k<6;k=k+1) observed[k]=0;
                active=1;
            end else begin
                if(observed[0]!==`C.bp_cf_retired-base[0] || observed[1]!==`C.bp_hits-base[1] || observed[2]!==`C.bp_taken_predictions-base[2] ||
                   observed[3]!==`C.bp_mispredictions-base[3] || observed[4]!==`C.bp_conditional_retired-base[4] || observed[5]!==`C.bp_direction_misses-base[5])
                    $fatal(1,"Branch statistics do not match independent retired-event sampling");
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,observed[0],observed[1],observed[2],observed[3],observed[4],observed[5]);
                $fflush(fd); active=0; run=run+1;
                if(run==4) $display("BP_STATS_PASS runs=4");
            end
        end
        if(active) begin
            if(`C.retire_valid && !`C.retire_trap)observe(`C.retire_insn,`C.w_prediction_hit,`C.w_prediction_taken,`C.w_prediction_wrong,`C.w_taken);
            if(`C.retire2_valid)observe(`C.retire2_insn,`C.w2_hit,`C.w2_pred_taken,`C.w2_wrong,`C.w2_taken);
        end
    end
endmodule
`undef C
`undef S
