`timescale 1ns/1ps
module tb_dual_prediction;
    parameter GS=1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,stop=1,redir=0,ready=0,take=0,take2=0,err=0,err2=0;
    reg [31:0] data=32'h13,data2=32'h13;
    reg uv=0,uc=0,ut=0,flush=0;
    reg [31:0] upc=0,utarget=0,uinsn=0;
    reg [7:0] uindex=0;
    wire rv,bv,bv2,be,be2,ph,pt,pr;
    wire [31:0] addr,pc,pc2,insn,insn2,npc;
    wire [7:0] pindex;
    rv32_fetch #(.DEPTH(4),.BYPASS(1),.DUAL_ENABLE(1),.WIDE_FETCH(1),.GSHARE_ENABLE(GS),.RAS_DEPTH(8)) dut(
        .clk(clk),.rst(rst),.stop(stop),.redirect(redir),.redirect_pc(32'b0),.req_valid(rv),.req_addr(addr),
        .rsp_ready(ready),.rsp_data(data),.rsp_error(err),.rsp_second_valid(1'b1),.rsp_second_error(err2),.rsp_data_second(data2),
        .buf_valid(bv),.buf_pc(pc),.buf_insn(insn),.buf_error(be),.buf_ready(take),.buf_second_valid(bv2),
        .buf_second_pc(pc2),.buf_second_insn(insn2),.buf_second_error(be2),.buf_take_second(take2),
        .buf_predicted_next_pc(npc),.buf_prediction_hit(ph),.buf_prediction_taken(pt),.buf_prediction_ras(pr),.buf_prediction_index(pindex),
        .bp_update_valid(uv),.bp_update_conditional(uc),.bp_update_taken(ut),.bp_update_pc(upc),.bp_update_target(utarget),
        .bp_update_insn(uinsn),.bp_update_index(uindex),.bp_flush(flush));
    task reset_case;
        begin
            @(negedge clk);rst=1;stop=1;redir=0;ready=0;take=0;take2=0;uv=0;flush=0;err=0;err2=0;
            repeat(3)@(negedge clk);rst=0;
        end
    endtask
    task train(input [31:0] a,input [31:0] t,input [31:0] i,input c);
        begin
            @(negedge clk);uv=1;upc=a;utarget=t;uinsn=i;uc=c;ut=1;uindex=0;
            @(negedge clk);uv=0;
        end
    endtask
    task capture(input [31:0] first,input [31:0] second);
        begin
            @(negedge clk);stop=0;redir=1;data=first;data2=second;
            @(negedge clk);redir=0;ready=1;
            @(posedge clk);#1;
            @(negedge clk);ready=0;
            #1;
        end
    endtask
    integer mode;
    initial begin
        // Nonsequential first-word prediction suppresses the adjacent response.
        reset_case();train(0,32'h100,32'h0000006f,0);capture(32'h0000006f,32'h13);
        if(!bv || bv2 || pc!=0 || npc!=32'h100 || !ph || !pt || addr!=32'h100 || dut.count!=1)$fatal(1,"First-word taken prediction");
        // A taken branch whose target equals PC+4 still preserves word1.
        reset_case();train(0,4,32'h0000006f,0);capture(32'h0000006f,32'h13);
        if(!bv2 || pc2!=4 || npc!=4 || !pt || addr!=8 || dut.count!=2)$fatal(1,"Taken fallthrough word lost");
        // Prediction metadata belongs to each stored word, not current GHR.
        reset_case();train(4,32'h200,32'h0000006f,0);train(32'h80,32'h84,32'h00000063,1);
        capture(32'h13,32'h0000006f);
        if(!bv2 || addr!=32'h200 || npc!=4 || pindex!=(GS?1:0))$fatal(1,"Second query target");
        train(32'h84,32'h88,32'h00000063,1);
        @(negedge clk);take=1;
        @(posedge clk);#1;
        if(!bv || pc!=4 || npc!=32'h200 || !ph || !pt || pr || pindex!=0)$fatal(1,"Saved second prediction metadata");
        // RAS applies to a return in word1 and advances the next request.
        reset_case();train(32'h300,32'h400,32'h000000ef,0);capture(32'h13,32'h00008067);
        if(!bv2 || addr!=32'h304)$fatal(1,"Second RAS target");
        @(negedge clk);take=1;
        @(posedge clk);#1;
        if(pc!=4 || npc!=32'h304 || !pr || !ph || !pt)$fatal(1,"Second RAS metadata");
        // Errors suppress predictor use and remain attached to the right word.
        for(mode=0;mode<2;mode=mode+1)begin
            reset_case();train(0,32'h100,32'h0000006f,0);train(4,32'h200,32'h0000006f,0);
            err=(mode==0);err2=(mode==1);capture(mode==0?32'h0000006f:32'h13,32'h0000006f);
            if(mode==0)begin
                if(!be || ph || pt || npc!=4 || bv2 || addr!=4)$fatal(1,"Primary error prediction");
            end else begin
                if(!bv2 || !be2 || addr!=8)$fatal(1,"Secondary error lost");
                @(negedge clk);take=1;
                @(posedge clk);#1;
                if(pc!=4 || !be || ph || pt || pr || npc!=8)$fatal(1,"Secondary error prediction");
            end
        end
        $display("DUAL_PREDICTION_PASS cases=6 gshare=%0d",GS);$finish;
    end
endmodule
