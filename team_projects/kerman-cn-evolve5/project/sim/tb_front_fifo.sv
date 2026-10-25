`timescale 1ns/1ps
module tb_front_fifo;
    parameter D=2,BYPASS=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,stop=0,redirect=0,ready=0,take=0;
    reg [31:0] target=0;
    wire rv,bv,be,ph,pt,pr;
    wire [31:0] addr,pc,insn,npc;
    wire [7:0] index;
    wire [31:0] data=32'ha0000013 ^ addr;
    wire error=ready && ((addr>>2)%29==5);
    rv32_fetch #(.BP_ENABLE(0),.DEPTH(D),.BYPASS(BYPASS)) dut(
        .clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(target),
        .req_valid(rv),.req_addr(addr),.rsp_ready(ready),.rsp_data(data),.rsp_error(error),
        .buf_valid(bv),.buf_pc(pc),.buf_insn(insn),.buf_error(be),.buf_ready(take),
        .buf_predicted_next_pc(npc),.buf_prediction_hit(ph),.buf_prediction_taken(pt),.buf_prediction_ras(pr),.buf_prediction_index(index),
        .bp_update_valid(1'b0),.bp_update_conditional(1'b0),.bp_update_taken(1'b0),.bp_update_pc(32'b0),.bp_update_target(32'b0),
        .bp_update_insn(32'b0),.bp_update_index(8'b0),.bp_flush(1'b0));
    reg [31:0] qp[0:8191],qd[0:8191];reg qe[0:8191];
    integer head=0,tail=0,epoch=0,request_epoch=0,n;
    integer consumed=0,discarded=0,redirects=0,stops=0,full=0,simultaneous=0,directs=0,faults=0;
    reg waiting=0,oldstop=0,live,direct_consumed,expected_valid,consumed_this;
    reg [31:0] held=0,request_pc=0,next_addr=0,ep,ed,rng=32'h4519bca7;
    reg ee;
    initial begin
        repeat(3) @(posedge clk);
        for(n=0;n<6000;n=n+1) begin
            @(negedge clk);
            rng=rng*32'd1664525+32'd1013904223;
            rst=(n==0 || n==1700 || n==3600);
            stop=!rst && (n%97>=91);
            redirect=!rst && !stop && (oldstop || (rng[5:0]==9));
            target=((rng>>7)&1023)*4;
            ready=(n<80) || (rng[10:9]==0);
            take=(n>=40 && n<80) || (n>=80 && rng[12]);
            oldstop=stop;
            @(posedge clk);
            if(rst) begin head=0;tail=0;epoch=epoch+1;waiting=0;next_addr=0;end
            else begin
                if(waiting && (!rv || addr!==held)) $fatal(1,"Outstanding fetch cancelled D=%0d",D);
                if(rv && !waiting) begin
                    if(addr!==next_addr) $fatal(1,"Wrong new request PC D=%0d n=%0d got=%h expected=%h",D,n,addr,next_addr);
                    request_epoch=epoch;request_pc=addr;
                end
                live=rv && ready && request_epoch==epoch && !stop && !redirect;
                direct_consumed=0;consumed_this=0;
                if(!stop && !redirect) begin
                    expected_valid=(tail!=head) || (BYPASS && live);
                    if(bv!==expected_valid) $fatal(1,"FIFO valid mismatch D=%0d n=%0d",D,n);
                    if(expected_valid) begin
                        if(tail!=head) begin ep=qp[head];ed=qd[head];ee=qe[head];end
                        else begin ep=request_pc;ed=data;ee=error;end
                        if({pc,insn,be,npc,ph,pt,pr,index}!=={ep,ed,ee,ep+32'd4,1'b0,1'b0,1'b0,8'b0})
                            $fatal(1,"FIFO metadata/order mismatch D=%0d n=%0d",D,n);
                        if(take) begin
                            consumed=consumed+1;consumed_this=1;if(be) faults=faults+1;
                            if(tail!=head) head=head+1;
                            else begin direct_consumed=1;directs=directs+1;end
                        end
                    end
                    if(live && !direct_consumed) begin qp[tail]=request_pc;qd[tail]=data;qe[tail]=error;tail=tail+1;end
                    if(live) next_addr=request_pc+4;
                    if(live && consumed_this) simultaneous=simultaneous+1;
                end
                if(rv && ready && !live) discarded=discarded+1;
                if(stop || redirect) begin
                    head=0;tail=0;epoch=epoch+1;
                    if(redirect) begin next_addr=target;redirects=redirects+1;end
                    if(stop) stops=stops+1;
                end
                waiting=rv && !ready;held=addr;
                if(tail-head>D) $fatal(1,"FIFO overrun");
                if(tail-head==D) full=full+1;
            end
            #1;if(dut.count!==tail-head) $fatal(1,"Queue occupancy mismatch D=%0d n=%0d",D,n);
        end
        if(consumed<100 || discarded<10 || redirects<10 || stops<10 || full<10 || simultaneous<10 || faults<10 || (BYPASS && directs<10))
            $fatal(1,"FIFO coverage missing D=%0d",D);
        $display("FRONT_FIFO_PASS D=%0d BYPASS=%0d consumed=%0d discarded=%0d full=%0d simultaneous=%0d direct=%0d faults=%0d",D,BYPASS,consumed,discarded,full,simultaneous,directs,faults);
        $finish;
    end
endmodule
