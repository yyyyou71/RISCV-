`timescale 1ns/1ps
// Retire-trained BTB, committed-history gshare and committed return stack.
// PHT training uses the index saved at prediction, not a newly computed index.
module rv32_predictor #(
    parameter integer ENABLE=1, INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0
)(
    input wire clk,rst,
    input wire [31:0] query_pc,query_insn,
    input wire query_error,
    output wire hit,taken,
    output wire [31:0] next_pc,
    output wire [PHT_BITS-1:0] prediction_index,
    output wire ras_hit,
    input wire update_valid,update_conditional,update_taken,
    input wire [31:0] update_pc,update_target,update_insn,
    input wire [PHT_BITS-1:0] update_index,
    input wire context_flush
);
    localparam integer ENTRIES=1<<INDEX_BITS;
    wire [6:0] opcode=query_insn[6:0];
    wire [2:0] f3=query_insn[14:12];
    wire conditional=opcode==7'h63 && (f3==0 || f3==1 || f3==4 || f3==5 || f3==6 || f3==7);
    wire control=conditional || opcode==7'h6f || (opcode==7'h67 && f3==0);
    generate if(ENABLE) begin: table_enabled
        reg [ENTRIES-1:0] valid;
        reg [29-INDEX_BITS:0] tags[0:ENTRIES-1];
        reg [29:0] targets[0:ENTRIES-1];
        reg [1:0] direction[0:ENTRIES-1];
        wire [INDEX_BITS-1:0] qi=query_pc[INDEX_BITS+1:2];
        wire [INDEX_BITS-1:0] ui=update_pc[INDEX_BITS+1:2];
        wire same_entry=valid[ui] && tags[ui]==update_pc[31:INDEX_BITS+2];
        wire btb_hit=!rst && !query_error && control && valid[qi] && tags[qi]==query_pc[31:INDEX_BITS+2];
        wire direction_taken;
        wire [31:0] ras_target;
        assign hit=btb_hit || ras_hit;
        assign taken=ras_hit || (btb_hit && (!conditional || direction_taken));
        assign next_pc=ras_hit ? ras_target : taken ? {targets[qi],2'b00} : query_pc+32'd4;
        always @(posedge clk) begin
            if(rst) valid<=0;
            else if(update_valid) begin
                if(update_taken) begin
                    valid[ui]<=1;
                    tags[ui]<=update_pc[31:INDEX_BITS+2];
                    targets[ui]<=update_target[31:2];
                    if(!update_conditional) direction[ui]<=2'b11;
                    else if(!same_entry) direction[ui]<=2'b10;
                    else if(direction[ui]!=2'b11) direction[ui]<=direction[ui]+2'b01;
                end else if(update_conditional && same_entry && direction[ui]!=2'b00)
                    direction[ui]<=direction[ui]-2'b01;
            end
        end
        if(GSHARE_ENABLE) begin: gshare
            localparam integer PHT_ENTRIES=1<<PHT_BITS;
            reg [PHT_BITS-1:0] history;
            reg [PHT_ENTRIES-1:0] pht_valid;
            reg [1:0] counters[0:PHT_ENTRIES-1];
            wire [PHT_BITS-1:0] index=query_pc[PHT_BITS+1:2]^history;
            assign prediction_index=index;
            assign direction_taken=pht_valid[index] && counters[index][1];
            always @(posedge clk) begin
                if(rst) begin history<=0; pht_valid<=0; end
                else begin
                    if(context_flush) history<=0;
                    else if(update_valid && update_conditional) history<={history[PHT_BITS-2:0],update_taken};
                    if(update_valid && update_conditional) begin
                        pht_valid[update_index]<=1;
                        if(!pht_valid[update_index]) counters[update_index]<=update_taken?2'b10:2'b01;
                        else if(update_taken && counters[update_index]!=3) counters[update_index]<=counters[update_index]+1'b1;
                        else if(!update_taken && counters[update_index]!=0) counters[update_index]<=counters[update_index]-1'b1;
                    end
                end
            end
        end else begin: bimodal
            assign direction_taken=direction[qi][1];
            assign prediction_index={PHT_BITS{1'b0}};
        end
        if(RAS_DEPTH>0) begin: ras
            reg [31:0] stack[0:RAS_DEPTH-1];
            reg [$clog2(RAS_DEPTH+1)-1:0] count;
            wire u_rd_link=(update_insn[11:7]==1 || update_insn[11:7]==5);
            wire u_rs_link=(update_insn[19:15]==1 || update_insn[19:15]==5);
            wire u_jalr=update_insn[6:0]==7'h67 && update_insn[14:12]==0;
            wire push=u_rd_link && (update_insn[6:0]==7'h6f || u_jalr);
            wire pop=u_jalr && u_rs_link && (!u_rd_link || update_insn[11:7]!=update_insn[19:15]);
            wire q_rd_link=(query_insn[11:7]==1 || query_insn[11:7]==5);
            wire q_rs_link=(query_insn[19:15]==1 || query_insn[19:15]==5);
            wire q_pop=q_rs_link && (!q_rd_link || query_insn[11:7]!=query_insn[19:15]);
            // Nonzero-offset JALR uses the BTB; only zero-offset returns use RAS.
            assign ras_hit=!rst && !query_error && opcode==7'h67 && f3==0 && query_insn[31:20]==0 && q_pop && count!=0;
            assign ras_target=stack[0];
            integer k;
            always @(posedge clk) begin
                if(rst || context_flush) count<=0;
                else if(update_valid) begin
                    if(push && pop) begin
                        stack[0]<=update_pc+4;
                        if(count==0) count<=1;
                    end else if(push) begin
                        for(k=RAS_DEPTH-1;k>0;k=k-1) stack[k]<=stack[k-1];
                        stack[0]<=update_pc+4;
                        if(count<RAS_DEPTH) count<=count+1'b1;
                    end else if(pop && count!=0) begin
                        for(k=0;k<RAS_DEPTH-1;k=k+1) stack[k]<=stack[k+1];
                        count<=count-1'b1;
                    end
                end
            end
        end else begin: ras_disabled
            assign ras_hit=1'b0;
            assign ras_target=32'b0;
        end
    end else begin: table_disabled
        assign hit=1'b0;
        assign taken=1'b0;
        assign ras_hit=1'b0;
        assign prediction_index={PHT_BITS{1'b0}};
        assign next_pc=query_pc+32'd4;
    end endgenerate
endmodule
