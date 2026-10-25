`timescale 1ns/1ps
`define C tb_coremark.dut.u_soc.cpu
`define S tb_coremark.dut.u_soc
module front_profile_monitor;
    reg active=0;
    reg [63:0] counts[0:9];
    integer fd,run=0,k;
    wire sample=!tb_coremark.dut.soc_reset && `S.fabric.pv && !`S.fabric.pw && `S.fabric.p_ready && `S.fabric.pa==32'h40002000;
    wire returning=`C.retire_insn[6:0]==7'h67 && `C.retire_insn[11:7]==0 &&
        (`C.retire_insn[19:15]==1 || `C.retire_insn[19:15]==5) && `C.retire_insn[31:20]==0;
    initial begin
        fd=$fopen("front_metrics.csv","w");
        $fdisplay(fd,"run,cycles,load_dependency,load_blocked,load_forwarded,fetch_empty,fetch_full,ras_retired,returns_retired,return_misses,redirects");
    end
    always @(posedge tb_coremark.clk) begin
        if(sample) begin
            if(!active) begin for(k=0;k<10;k=k+1) counts[k]=0;active=1;end
            else begin
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",run,counts[0],counts[1],counts[2],counts[3],counts[4],counts[5],counts[6],counts[7],counts[8],counts[9]);
                $fflush(fd); active=0;run=run+1;if(run==4) $display("FRONT_PROFILE_PASS runs=4");
            end
        end
        if(active) begin
            counts[0]=counts[0]+1;
            if(`C.load_dependency) counts[1]=counts[1]+1;
            if(`C.load_hazard) counts[2]=counts[2]+1;
            if(`C.load_dependency && (`C.load_available || `C.load_available2) && (`C.x_fire || `C.md_request)) counts[3]=counts[3]+1;
            if(!`C.id_valid) counts[4]=counts[4]+1;
            if(`C.fetch.count==tb_coremark.dut.FETCH_DEPTH) counts[5]=counts[5]+1;
            if(`C.retire_valid && !`C.retire_trap) begin
                if(`C.w_prediction_ras) counts[6]=counts[6]+1;
                if(returning) begin
                    counts[7]=counts[7]+1;
                    if(`C.w_prediction_wrong) counts[8]=counts[8]+1;
                end
            end
            if(`C.retire2_valid)begin
                if(`C.w2_ras)counts[6]=counts[6]+1;
                if(`C.retire2_insn[6:0]==7'h67 && `C.retire2_insn[11:7]==0 && (`C.retire2_insn[19:15]==1 || `C.retire2_insn[19:15]==5) && `C.retire2_insn[31:20]==0)begin
                    counts[7]=counts[7]+1;
                    if(`C.w2_wrong)counts[8]=counts[8]+1;
                end
            end
            if(`C.prediction_recovery) counts[9]=counts[9]+1;
        end
    end
endmodule
`undef C
`undef S
