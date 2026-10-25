"""Insert real cache RTL into the existing precise-trap CPU test harness.

Keep CPU observations on the demand side, move only the memory model to the
backend side, and assert both completion-handshake interfaces independently.
The test memory map is flat, unlike the physical SoC map.
"""
import re

def cached_testbench(source,enabled,wide=0):
    source=source.replace('    rv32_core', '    wire isv;wire [31:0] isdata;\n    rv32_core',1)
    source=source.replace('.imem_error(ie),', ".imem_error(ie),.imem_second_valid(isv),.imem_second_error(1'b0),.imem_rdata_second(isdata),")
    instances=f'''
    wire biv,bir,bie,bdv,bdw,bdr,bde;
    wire [31:0] bia,bidata,bda,bwd,brdata; wire [3:0] bws;
    wire [31:0] ih,im,dh,dm,wh,wm;
    rv32_icache #(.BURST_INTERFACE(1),.WIDE_FETCH({wide}),.ENABLE({enabled}),.ROM_BYTES(32'hf000)) icache (
        .clk(clk),.rst(rst),.valid(iv),.addr(ia),.ready(ir),.rdata(idata),.error(ie),.second_valid(isv),.rdata_second(isdata),
        .mem_valid(biv),.mem_addr(bia),.mem_ready(bir),.mem_rdata(bidata),.mem_error(bie),
        .read_hits(ih),.read_misses(im),.refill_words(),.refill_errors());
    rv32_dcache #(.ENABLE({enabled}),.ROM_BYTES(32'h8000),.RAM_BASE(32'h8000),.RAM_BYTES(32'h7000)) dcache (
        .clk(clk),.rst(rst),.valid(dv),.write(dw),.addr(da),.wdata(wd),.wstrb(ws),.ready(dr),.rdata(rdata),.error(de),
        .mem_valid(bdv),.mem_write(bdw),.mem_addr(bda),.mem_wdata(bwd),.mem_wstrb(bws),.mem_ready(bdr),.mem_rdata(brdata),.mem_error(bde),
        .read_hits(dh),.read_misses(dm),.write_hits(wh),.write_misses(wm),.bypass_requests(),.refill_words(),.refill_errors());
    reg biwait=0,bdwait=0; reg [31:0] prev_bia; reg [68:0] prev_bdp;
    always @(posedge clk) begin
        if(rst) begin biwait=0; bdwait=0; end
        else begin
            if(biwait && (!biv || bia!==prev_bia)) $fatal(1,"Cache instruction backend request changed");
            if(bdwait && (!bdv || {{bdw,bda,bwd,bws}}!==prev_bdp)) $fatal(1,"Cache data backend request changed");
            biwait=biv&&!bir; prev_bia=bia; bdwait=bdv&&!bdr; prev_bdp={{bdw,bda,bwd,bws}};
        end
    end
'''
    source=source.replace('    reg [7:0] mem',instances+'    reg [7:0] mem')
    names={'iv':'biv','ir':'bir','ie':'bie','ia':'bia','idata':'bidata','dv':'bdv','dw':'bdw','dr':'bdr','de':'bde','da':'bda','wd':'bwd','ws':'bws','rdata':'brdata'}
    def replace(block): return re.sub(r'\b('+ '|'.join(names)+r')\b',lambda m:names[m[0]],block)
    start=source.index('    assign ir='); stop=source.index('    integer k,cycles',start)
    source=source[:start]+replace(source[start:stop])+source[stop:]
    source=source.replace('scene>=2 && scene<=5 && !started && dv && !dr',
                          '((scene>=2 && scene<=5) || scene==7) && !started && dv && !dr && (scene!=7 || dw)')
    source=source.replace('scene==3 && writes8000!=1','(scene==3 || scene==7) && writes8000!=1')
    start=source.index('            if(iv&&ir)'); stop=source.index('            if(scene==6',start)
    source=source[:start]+replace(source[start:stop])+source[stop:]
    source=source.replace('bp_hits,bp_mispredictions"','bp_hits,bp_mispredictions,icache_hits,icache_misses,dcache_hits,dcache_misses,dcache_write_hits,dcache_write_misses"')
    source=source.replace('"%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",name,cycles,irqs,traps,returns,reads8000,writes8000,dut.bp_hits,dut.bp_mispredictions',
                          '"%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",name,cycles,irqs,traps,returns,reads8000,writes8000,dut.bp_hits,dut.bp_mispredictions,ih,im,dh,dm,wh,wm')
    source=source.replace('#(.ENABLE(', '#(.BURST_INTERFACE(1),.ENABLE(')
    for prefix in ('i','d'):
        stem='bi' if prefix=='i' else 'bd'
        fields={'mem_valid':stem+'v','mem_addr':stem+'a'}
        if prefix=='d': fields.update(mem_write='bdw',mem_wdata='bwd',mem_wstrb='bws')
        for name,wire in fields.items(): source=source.replace(f'.{name}({wire})',f'.{name}()')
    for name,wire,zero in [('mem_ready','bir',"1'b0"),('mem_error','bie',"1'b0"),('mem_rdata','bidata',"32'b0"),
                           ('mem_ready','bdr',"1'b0"),('mem_error','bde',"1'b0"),('mem_rdata','brdata',"32'b0")]:
        source=source.replace(f'.{name}({wire})',f'.{name}({zero})')
    declarations=''
    for prefix,hit in (('i','ih'),('d','dh')):
        declarations+=f'    wire {prefix}cv,{prefix}cr,{prefix}cw,{prefix}rv,{prefix}rr,{prefix}re,{prefix}rl; wire [31:0] {prefix}ca,{prefix}cd,{prefix}rd; wire [3:0] {prefix}cs; wire [7:0] {prefix}cl;\n'
        port=f'.cmd_valid({prefix}cv),.cmd_ready({prefix}cr),.cmd_write({prefix}cw),.cmd_addr({prefix}ca),.cmd_wdata({prefix}cd),.cmd_wstrb({prefix}cs),.cmd_len({prefix}cl),.rsp_valid({prefix}rv),.rsp_ready({prefix}rr),.rsp_data({prefix}rd),.rsp_error({prefix}re),.rsp_last({prefix}rl),'
        source=source.replace(f'.read_hits({hit})',port+f'.read_hits({hit})')
        down='.mv(biv),.mw(),.ma(bia),.md(),.ms(),.mr(bir),.me(bie),.mdata(bidata)' if prefix=='i' else '.mv(bdv),.mw(bdw),.ma(bda),.md(bwd),.ms(bws),.mr(bdr),.me(bde),.mdata(brdata)'
        declarations+=f'    burst_word_test_adapter {prefix}transport(.clk(clk),.rst(rst),.cv({prefix}cv),.cr({prefix}cr),.cw({prefix}cw),.ca({prefix}ca),.cd({prefix}cd),.cs({prefix}cs),.cl({prefix}cl),.rv({prefix}rv),.rr({prefix}rr),.rd({prefix}rd),.re({prefix}re),.rl({prefix}rl),{down});\n'
    source=source.replace('    wire [31:0] ih,im,dh,dm,wh,wm;','    wire [31:0] ih,im,dh,dm,wh,wm;\n'+declarations)
    return source
