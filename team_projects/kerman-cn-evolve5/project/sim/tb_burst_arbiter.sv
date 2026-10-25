`timescale 1ns/1ps
module tb_burst_arbiter;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,block_cmd=0;
    reg [1:0] v=0,w=0,ready_rsp=0;
    reg [31:0] a[0:1],d[0:1]; reg [3:0] s[0:1]; reg [7:0] len[0:1];
    wire [1:0] ready,rvalid,rerror,rlast; wire [31:0] rdata[0:1];
    wire cv,cr,cw,ci,rv,rr,re,rl; wire [31:0] ca,cd,rd; wire [3:0] cs; wire [7:0] cl;
    rv32_burst_arbiter dut(.clk(clk),.rst(rst),
        .i_valid(v[0]),.i_ready(ready[0]),.i_write(w[0]),.i_addr(a[0]),.i_wdata(d[0]),.i_wstrb(s[0]),.i_len(len[0]),
        .i_rsp_valid(rvalid[0]),.i_rsp_ready(ready_rsp[0]),.i_rsp_data(rdata[0]),.i_rsp_error(rerror[0]),.i_rsp_last(rlast[0]),
        .d_valid(v[1]),.d_ready(ready[1]),.d_write(w[1]),.d_addr(a[1]),.d_wdata(d[1]),.d_wstrb(s[1]),.d_len(len[1]),
        .d_rsp_valid(rvalid[1]),.d_rsp_ready(ready_rsp[1]),.d_rsp_data(rdata[1]),.d_rsp_error(rerror[1]),.d_rsp_last(rlast[1]),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_instr(ci),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_data(rd),.rsp_error(re),.rsp_last(rl));
    reg busy=0; reg [31:0] saved_addr; reg [7:0] saved_len,beat;
    integer delay_count=0,cycles=0,served_i=0,served_d=0,error_beats=0,contended=0;
    reg last_owner=1,cwait=0; reg [77:0] previous_command;
    assign cr=!rst && !busy && !block_cmd && cycles%7!=0;
    assign rv=!rst && busy && delay_count==0;
    assign rd=(saved_addr+beat*4)^32'ha5c35a7e;
    assign re=saved_addr[8:6]==3 && beat==saved_len;
    assign rl=beat==saved_len;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>100000) $fatal(1,"Arbiter test timed out/starved");
        if(rst) begin busy<=0; delay_count<=0; beat<=0; saved_addr<=0; saved_len<=0; cwait=0; last_owner=1; end
        else begin
            if(cwait && (!cv || {ci,cw,ca,cd,cs,cl}!==previous_command)) $fatal(1,"Grant switched before command acceptance");
            cwait=cv&&!cr; previous_command={ci,cw,ca,cd,cs,cl};
            if(ready==2'b11 || rvalid==2'b11) $fatal(1,"Both masters received one transaction");
            if(cv&&cr) begin
                if(busy) $fatal(1,"Arbiter interleaved transactions");
                if({cw,ca,cd,cs,cl}!=={w[!ci],a[!ci],d[!ci],s[!ci],len[!ci]}) $fatal(1,"Command payload corrupted");
                if(v==2'b11 && dut.state==0) begin
                    contended=contended+1; if((!ci)==last_owner) $fatal(1,"Round-robin fairness failed");
                end
                last_owner=!ci;
                if(ci) served_i=served_i+1; else served_d=served_d+1;
                busy<=1; saved_addr<=ca; saved_len<=cl; beat<=0; delay_count<=cycles%4;
            end else if(busy && delay_count>0) delay_count<=delay_count-1;
            if(rv&&rr) begin
                if(re) error_beats=error_beats+1;
                if(rl) busy<=0;
                else begin beat<=beat+1'b1; delay_count<=cycles%3; end
            end
        end
    end
    task automatic reset_all;
        begin
            @(negedge clk); rst=1; v=0; ready_rsp=0;
            repeat(3) @(posedge clk);
            @(negedge clk); rst=0;
        end
    endtask
    task automatic client(input integer id);
        integer n,b,guard; reg [31:0] base; reg err;
        begin
            for(n=0;n<48;n=n+1) begin
                @(negedge clk); base=(id?32'h20000000:0)+n*64;
                a[id]=base; d[id]=32'hfedcba98^n; s[id]=n%16; w[id]=id && n%7==0;
                len[id]=w[id]?0:(n%3==0?7:n%3==1?3:0); v[id]=1;
                @(posedge clk); while(!ready[id]) @(posedge clk);
                @(negedge clk); v[id]=0;
                for(b=0;b<=len[id];b=b+1) begin
                    guard=0;
                    begin: receive
                        forever begin
                            @(negedge clk); ready_rsp[id]=guard%4!=0;
                            @(posedge clk); guard=guard+1;
                            if(rvalid[id] && ready_rsp[id]) begin
                                err=base[8:6]==3 && b==len[id];
                                if(rdata[id]!==((base+b*4)^32'ha5c35a7e) || rerror[id]!==err || rlast[id]!==(b==len[id]))
                                    $fatal(1,"Misrouted response master=%0d command=%0d beat=%0d",id,n,b);
                                #1; disable receive;
                            end
                            #1;
                        end
                    end
                end
                ready_rsp[id]=0;
            end
        end
    endtask
    initial begin
        a[0]=0; a[1]=32'h20000000; d[0]=0; d[1]=0; s[0]=0; s[1]=15; len[0]=3; len[1]=0;
        reset_all(); block_cmd=1;
        @(negedge clk); v[0]=1;
        repeat(2) @(posedge clk);
        @(negedge clk); v[1]=1;
        repeat(5) begin @(posedge clk); if(!ci || ca!=0) $fatal(1,"Stalled grant lost to a late requester"); end
        reset_all(); block_cmd=0;
        // Abandon only via a common reset while a response is stalled.
        @(negedge clk); v[0]=1;
        @(posedge clk); while(!ready[0]) @(posedge clk);
        @(negedge clk); v[0]=0; wait(rv); repeat(4) @(posedge clk); reset_all();
        served_i=0; served_d=0; error_beats=0; contended=0;
        fork client(0); client(1); join
        if(served_i!=48 || served_d!=48 || error_beats==0 || contended<20 || busy) $fatal(1,"Incomplete arbiter coverage");
        $display("BURST_ARBITER_PASS i_commands=%0d d_commands=%0d error_beats=%0d contended_grants=%0d",served_i,served_d,error_beats,contended); $finish;
    end
endmodule
