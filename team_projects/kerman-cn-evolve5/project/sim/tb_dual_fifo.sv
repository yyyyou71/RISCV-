`timescale 1ns/1ps
module tb_dual_fifo;
    parameter D=4,BYPASS=1,DUAL=1,WIDE=1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,stop=0,redirect=0,ready=0,take=0,take2=0,second=0;
    reg [31:0] target=0;
    wire rv,bv,bv2,be,be2,ph,pt,pr;
    wire [31:0] addr,pc,pc2,insn,insn2,npc;
    wire [7:0] pindex;
    wire [31:0] next_address=addr+4;
    wire [31:0] data=32'ha0000013^addr,data2=32'ha0000013^next_address;
    wire error=ready && ((addr>>2)%31==7);
    wire error2=ready && ((next_address>>2)%23==4);
    rv32_fetch #(.BP_ENABLE(0),.DEPTH(D),.BYPASS(BYPASS),.DUAL_ENABLE(DUAL),.WIDE_FETCH(WIDE)) dut(
        .clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(target),
        .req_valid(rv),.req_addr(addr),.rsp_ready(ready),.rsp_data(data),.rsp_error(error),
        .rsp_second_valid(second),.rsp_second_error(error2),.rsp_data_second(data2),
        .buf_valid(bv),.buf_pc(pc),.buf_insn(insn),.buf_error(be),.buf_ready(take),
        .buf_second_valid(bv2),.buf_second_pc(pc2),.buf_second_insn(insn2),.buf_second_error(be2),.buf_take_second(take2),
        .buf_predicted_next_pc(npc),.buf_prediction_hit(ph),.buf_prediction_taken(pt),.buf_prediction_ras(pr),.buf_prediction_index(pindex),
        .bp_update_valid(1'b0),.bp_update_conditional(1'b0),.bp_update_taken(1'b0),.bp_update_pc(32'b0),.bp_update_target(32'b0),
        .bp_update_insn(32'b0),.bp_update_index(8'b0),.bp_flush(1'b0));
    reg [31:0] qp[0:16383],qd[0:16383];reg qe[0:16383];
    reg [31:0] held=0,request_pc=0,next_pc=0,rng=32'h7d0a1101;
    reg waiting=0,previous_stop=0,live,expected0,expected1;
    integer head=0,tail=0,epoch=0,request_epoch=0,n,i,old_count,incoming,consume,stored_pop,direct_pop;
    integer retired_words=0,retired_second=0,paired_responses=0,discarded=0,full=0,errors_seen=0,simultaneous=0;
    reg [31:0] ep,ed;reg ee;
    task check_word(input integer offset);
        begin
            if(offset<old_count)begin ep=qp[head+offset];ed=qd[head+offset];ee=qe[head+offset];end
            else if(offset-old_count==0)begin ep=request_pc;ed=data;ee=error;end
            else begin ep=request_pc+4;ed=data2;ee=error2;end
            if(offset==0)begin
                if({pc,insn,be,npc,ph,pt,pr,pindex}!=={ep,ed,ee,ep+32'd4,1'b0,1'b0,1'b0,8'b0})$fatal(1,"Head0 mismatch n=%0d",n);
            end else if({pc2,insn2,be2}!=={ep,ed,ee})$fatal(1,"Head1 mismatch n=%0d",n);
        end
    endtask
    initial begin
        repeat(3)@(posedge clk);
        for(n=0;n<6000;n=n+1)begin
            @(negedge clk);rng=rng*1664525+1013904223;
            rst=(n==0 || n==1999 || n==4001);
            stop=!rst && n%113>=107;
            redirect=!rst && !stop && (previous_stop || rng[5:0]==11);
            target=((rng>>7)&2047)*4;
            ready=n<80 || rng[10:9]==0;
            take=(n>=40 && n<80) || (n>=80 && rng[12]);
            take2=n<80 || rng[14];second=n<80 || rng[16];previous_stop=stop;
            @(posedge clk);
            if(rst)begin head=0;tail=0;epoch=epoch+1;waiting=0;next_pc=0;end
            else begin
                if(waiting && (!rv || addr!==held))$fatal(1,"Pending request changed n=%0d",n);
                if(rv && !waiting)begin
                    if(addr!==next_pc)$fatal(1,"New request PC mismatch n=%0d got=%h want=%h",n,addr,next_pc);
                    request_pc=addr;request_epoch=epoch;
                end
                live=rv && ready && request_epoch==epoch && !stop && !redirect;
                incoming=live?((WIDE && second && !error)?2:1):0;
                old_count=tail-head;
                if(!stop && !redirect)begin
                    expected0=old_count!=0 || (BYPASS && incoming>0);
                    expected1=old_count>1 || (BYPASS && old_count+incoming>1);
                    if(bv!==expected0 || bv2!==expected1)$fatal(1,"Availability mismatch n=%0d count=%0d input=%0d",n,old_count,incoming);
                    if(expected0)check_word(0);
                    if(expected1)check_word(1);
                    consume=expected0 && take ? ((DUAL && take2 && expected1)?2:1):0;
                    for(i=0;i<consume;i=i+1)begin check_word(i);if(ee)errors_seen=errors_seen+1;end
                    stored_pop=consume>old_count?old_count:consume;direct_pop=consume-stored_pop;
                    head=head+stored_pop;retired_words=retired_words+consume;
                    if(consume==2)retired_second=retired_second+1;
                    for(i=direct_pop;i<incoming;i=i+1)begin
                        qp[tail]=request_pc+4*i;qd[tail]=i==0?data:data2;qe[tail]=i==0?error:error2;tail=tail+1;
                    end
                    if(incoming)next_pc=request_pc+4*incoming;
                    if(incoming==2)paired_responses=paired_responses+1;
                    if(incoming && consume)simultaneous=simultaneous+1;
                end
                if(rv && ready && !live)discarded=discarded+1;
                if(stop || redirect)begin head=0;tail=0;epoch=epoch+1;if(redirect)next_pc=target;end
                waiting=rv && !ready;held=addr;
                if(tail-head>D)$fatal(1,"Queue overflow");
                if(tail-head==D)full=full+1;
            end
            #1;if(dut.count!==tail-head)$fatal(1,"Queue count mismatch n=%0d count=%0d expected=%0d",n,dut.count,tail-head);
        end
        // Without bypass, a queue exactly as deep as the reserved response
        // cannot accept a response while exposing a stored head to consume.
        $display("FIFO_COVERAGE words=%0d discarded=%0d full=%0d faults=%0d overlap=%0d",retired_words,discarded,full,errors_seen,simultaneous);
        if(retired_words<100 || discarded<10 || full<10 || errors_seen<10 || ((BYPASS || D>(WIDE?2:1)) && simultaneous<10) ||
           (DUAL && retired_second==0) || (!DUAL && retired_second!=0) || (WIDE && paired_responses==0) || (!WIDE && paired_responses!=0))
            $fatal(1,"Coverage not reached");
        $display("DUAL_FIFO_PASS D=%0d BYPASS=%0d DUAL=%0d WIDE=%0d words=%0d pairs=%0d paired_responses=%0d discarded=%0d faults=%0d",D,BYPASS,DUAL,WIDE,retired_words,retired_second,paired_responses,discarded,errors_seen);$finish;
    end
endmodule
