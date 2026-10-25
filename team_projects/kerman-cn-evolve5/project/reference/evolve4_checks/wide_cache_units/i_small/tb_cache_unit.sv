// Parameterized source template expanded by cache_unit_regress.py.
`timescale 1ns/1ps
module tb_cache_unit;
    localparam integer ENABLE=1, INSTRUCTION=1, SET_BITS=1, LINE_WORD_BITS=2;
    localparam integer ROM_BYTES=32768,RAM_BYTES=32768;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,sv=0,sw=0;
    reg [31:0] sa=0,sd=0; reg [3:0] ss=0;
    wire sr,se,mv,mw,mr,me; wire [31:0] rd,ma,md,mdata; wire [3:0] ms;
    wire [31:0] rh,rm;
    wire cv,cr,cw,rv,rr,re,rl; wire [31:0] ca,cd,brd; wire [3:0] cs; wire [7:0] cl;
    integer commands=0,before_commands,expected_commands;
    burst_word_test_adapter transport(.clk(clk),.rst(rst),.cv(cv),.cr(cr),.cw(cw),.ca(ca),.cd(cd),.cs(cs),.cl(cl),
        .rv(rv),.rr(rr),.re(re),.rl(rl),.rd(brd),.mv(mv),.mw(mw),.ma(ma),.md(md),.ms(ms),.mr(mr),.me(me),.mdata(mdata));
    reg cw_wait=0,rsp_wait=0; reg [76:0] previous_cmd; reg [33:0] previous_response;
    always @(posedge clk) begin
        if(rst) begin cw_wait=0; rsp_wait=0; end
        else begin
            if(cw_wait && (!cv || {cw,ca,cd,cs,cl}!==previous_cmd)) $fatal(1,"Cache burst command changed during wait");
            if(rsp_wait && (!rv || {brd,re,rl}!==previous_response)) $fatal(1,"BFM response changed during wait");
            cw_wait=cv&&!cr; previous_cmd={cw,ca,cd,cs,cl}; rsp_wait=rv&&!rr; previous_response={brd,re,rl};
            if(cv&&cr) commands=commands+1;
        end
    end
    wire second_valid;wire [31:0] second_data;integer second_count=0;
    generate if(INSTRUCTION) begin

        rv32_icache #(.WIDE_FETCH(1),.BURST_INTERFACE(1),.BURST_FILL(1),.ENABLE(ENABLE),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES)) dut (
            .clk(clk),.rst(rst),.valid(sv),.addr(sa),.ready(sr),.error(se),.rdata(rd),.second_valid(second_valid),.rdata_second(second_data),
            .mem_valid(),.mem_addr(),.mem_ready(1'b0),.mem_error(1'b0),.mem_rdata(32'b0),.cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
            .rsp_valid(rv),.rsp_ready(rr),.rsp_data(brd),.rsp_error(re),.rsp_last(rl),.read_hits(rh),.read_misses(rm),.refill_words(),.refill_errors());
    end else begin
        assign second_valid=0;assign second_data=0;
        rv32_dcache #(.FAST_STORE(1),.BURST_INTERFACE(1),.BURST_FILL(1),.ENABLE(ENABLE),.SET_BITS(SET_BITS),.LINE_WORD_BITS(LINE_WORD_BITS),.ROM_BYTES(ROM_BYTES),.RAM_BYTES(RAM_BYTES)) dut (
            .clk(clk),.rst(rst),.valid(sv),.write(sw),.addr(sa),.wdata(sd),.wstrb(ss),.ready(sr),.error(se),.rdata(rd),
            .mem_valid(),.mem_write(),.mem_addr(),.mem_wdata(),.mem_wstrb(),.mem_ready(1'b0),.mem_error(1'b0),.mem_rdata(32'b0),
            .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
            .rsp_valid(rv),.rsp_ready(rr),.rsp_data(brd),.rsp_error(re),.rsp_last(rl),.read_hits(rh),.read_misses(rm),.write_hits(),.write_misses(),.bypass_requests(),.refill_words(),.refill_errors());
    end endgenerate
    reg [31:0] ram[0:8191];
    reg [31:0] fault=32'hffffffff,rng=32'h65b3179d;
    reg fault_write=0,busy=0,mwait=0,swait=0;
    reg [68:0] prev_m,prev_s;
    integer count=0,mode=0,beats=0,mmio_reads=0,cycles=0,j;
    wire [31:0] aligned=ma & 32'hfffffffc;
    wire rom=aligned<ROM_BYTES, ram_sel=aligned>=32'h20000000 && aligned<32'h20000000+RAM_BYTES;
    wire mmio=aligned==32'h40000000;
    wire legal=INSTRUCTION ? (rom && !mw && ma[1:0]==0) : ((rom && !mw) || ram_sel || mmio);
    function automatic integer delay(input integer mode_in,input [31:0] random_in);
        case(mode_in) 0:delay=0; 1:delay=1; 2:delay=random_in%6+1; default:delay=12; endcase
    endfunction
    assign mr=!rst && (busy ? count==0 : delay(mode,rng)==0);
    assign me=!legal || (aligned==fault && mw==fault_write);
    assign mdata=me?0:mmio?mmio_reads+1:ram_sel?ram[(aligned-32'h20000000)>>2]:(aligned^32'ha5c35a7e);
    always @(posedge clk) begin
        if(rst) begin busy<=0; count<=0; mwait=0; swait=0; end
        else begin
            cycles=cycles+1;
            if(cycles>2000000) $fatal(1,"Unit timeout");
            if(mwait && (!mv || {mw,ma,md,ms}!==prev_m)) $fatal(1,"Backend request changed while waiting");
            if(swait && (!sv || {sw,sa,sd,ss}!==prev_s)) $fatal(1,"CPU test request changed while waiting");
            mwait=mv&&!mr; prev_m={mw,ma,md,ms}; swait=sv&&!sr; prev_s={sw,sa,sd,ss};
            if(mv && mr) begin
                beats=beats+1; busy<=0; rng<=rng*1664525+1013904223;
                if(!me && !mw && mmio) mmio_reads<=mmio_reads+1;
                if(!me && mw && ram_sel) for(j=0;j<4;j=j+1) if(ms[j]) ram[(aligned-32'h20000000)>>2][8*j+:8]<=md[8*j+:8];
            end else if(mv && !busy) begin busy<=1; count<=delay(mode,rng)-1; end
            else if(busy && count>0) count<=count-1;
        end
    end
    always @(posedge clk) if(!rst && second_valid) begin
        if(!INSTRUCTION || !ENABLE || !sv || !sr || se || sa[1:0]!=0 || ((sa>>2)&((1<<LINE_WORD_BITS)-1))==((1<<LINE_WORD_BITS)-1) || sa+4>=ROM_BYTES)
            $fatal(1,"Invalid secondary I-cache response");
        if(second_data!==((sa+4)^32'ha5c35a7e))$fatal(1,"Secondary I-cache data mismatch");
        second_count=second_count+1;
    end
    integer vf,scan,op,err,expected_beats,fw,delay_mode,cases=0,before_beats,waited,finished,k;
    reg [31:0] address,value,expected,fault_addr;
    reg [3:0] mask;
    task automatic reset_cache;
        begin
            @(negedge clk); rst=1; sv=0;
            repeat(3) begin @(posedge clk); #1; if(mv || sr) $fatal(1,"Traffic during reset"); end
            @(negedge clk); rst=0;
        end
    endtask
    initial begin
        for(k=0;k<8192;k=k+1) ram[k]=(32'h20000000+k*4)^32'ha5c35a7e;
        reset_cache(); vf=$fopen("vectors.txt","r"); if(!vf) $fatal(1,"Missing vectors");
        while(!$feof(vf)) begin
            scan=$fscanf(vf,"%d %h %h %h %d %h %d %h %d %d %d\n",op,address,value,mask,err,expected,expected_beats,fault_addr,fw,delay_mode,expected_commands);
            if(scan==11) begin
                cases=cases+1;
                if(op==2) reset_cache();
                else begin
                    @(negedge clk); before_beats=beats; before_commands=commands; mode=delay_mode; fault=fault_addr; fault_write=fw;
                    sv=1; sw=op==1 || op==4; sa=address; sd=value; ss=mask;
                    if(op==3 || op==4) begin
                        if(op==3) begin wait(beats>before_beats); #1; if(sr) $fatal(1,"Partial refill acknowledged early"); end
                        else begin wait(mv); repeat(2) @(posedge clk); #1; end
                        reset_cache();
                    end else begin
                        waited=0; finished=0;
                        while(!finished && waited<500) begin
                            @(posedge clk);
                            if(sr) begin
                                if(se!==err[0] || (!sw && !err && rd!==expected))
                                    $fatal(1,"Case %0d addr=%08x write=%0d err=%0d/%0d data=%08x/%08x",cases,address,sw,se,err,rd,expected);
                                finished=1;
                            end
                            #1; waited=waited+1;
                        end
                        if(!finished) $fatal(1,"Request stuck case=%0d",cases);
                        @(negedge clk); sv=0;
                    end
                    repeat(2) @(negedge clk);
                    if(beats-before_beats!=expected_beats) $fatal(1,"Backend count case=%0d addr=%08x actual=%0d expected=%0d",cases,address,beats-before_beats,expected_beats);
                    if(commands-before_commands!=expected_commands) $fatal(1,"Command count case=%0d actual=%0d expected=%0d",cases,commands-before_commands,expected_commands);
                    if(mv) $fatal(1,"Unrequested backend traffic after completion");
                end
            end
        end
        if(INSTRUCTION && ENABLE && second_count==0)$fatal(1,"No wide cache hit observed");
        $display("WIDE_CACHE_PASS pairs=%0d",second_count);
        $display("CACHE_UNIT_PASS cases=%0d instruction=%0d enable=%0d set_bits=%0d line_word_bits=%0d",cases,INSTRUCTION,ENABLE,SET_BITS,LINE_WORD_BITS);
        $finish;
    end
endmodule
