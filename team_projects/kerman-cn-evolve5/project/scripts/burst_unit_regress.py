import argparse,hashlib,json,os,shutil,sys
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests'))
from cache_vectors import generate

def testbench(cfg):
    s=(PROJECT/'sim/tb_cache_unit.sv.in').read_text()
    for key,value in cfg.items(): s=s.replace('@'+key.upper()+'@',str(value))
    s=s.replace('        assign mw=0; assign md=0; assign ms=0;','')
    s=s.replace('#(.ENABLE(ENABLE)',f'#(.BURST_INTERFACE(1),.BURST_FILL({cfg["burst_fill"]}),.ENABLE(ENABLE)')
    if cfg.get('fast_store'):s=s.replace('rv32_dcache #(', 'rv32_dcache #(.FAST_STORE(1),')
    for token in ('mem_valid(mv)','mem_write(mw)','mem_addr(ma)','mem_wdata(md)','mem_wstrb(ms)'): s=s.replace('.'+token,'.'+token.split('(')[0]+'()')
    s=s.replace('.mem_ready(mr)',".mem_ready(1'b0)").replace('.mem_error(me)',".mem_error(1'b0)").replace('.mem_rdata(mdata)',".mem_rdata(32'b0)")
    s=s.replace('.read_hits(rh)', '''.cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
            .rsp_valid(rv),.rsp_ready(rr),.rsp_data(brd),.rsp_error(re),.rsp_last(rl),.read_hits(rh)''')
    marker='    generate if(INSTRUCTION)'
    extra='''    wire cv,cr,cw,rv,rr,re,rl; wire [31:0] ca,cd,brd; wire [3:0] cs; wire [7:0] cl;
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
'''
    s=s.replace(marker,extra+marker)
    s=s.replace('%d %h %h %h %d %h %d %h %d %d\\n','%d %h %h %h %d %h %d %h %d %d %d\\n').replace('fault_addr,fw,delay_mode);','fault_addr,fw,delay_mode,expected_commands);').replace('scan==10','scan==11')
    s=s.replace('before_beats=beats;', 'before_beats=beats; before_commands=commands;')
    s=s.replace('                    if(mv) $fatal', '                    if(commands-before_commands!=expected_commands) $fatal(1,"Command count case=%0d actual=%0d expected=%0d",cases,commands-before_commands,expected_commands);\n                    if(mv) $fatal')
    if cfg.get('wide_fetch'):
        s=s.replace('    generate if(INSTRUCTION)', '    wire second_valid;wire [31:0] second_data;integer second_count=0;\n    generate if(INSTRUCTION)')
        s=s.replace('rv32_icache #(', 'rv32_icache #(.WIDE_FETCH(1),')
        s=s.replace('.valid(sv),.addr(sa),.ready(sr),.error(se),.rdata(rd),', '.valid(sv),.addr(sa),.ready(sr),.error(se),.rdata(rd),.second_valid(second_valid),.rdata_second(second_data),')
        s=s.replace('    end else begin\n        rv32_dcache', "    end else begin\n        assign second_valid=0;assign second_data=0;\n        rv32_dcache")
        marker='    integer vf,scan'
        s=s.replace(marker,'''    always @(posedge clk) if(!rst && second_valid) begin
        if(!INSTRUCTION || !ENABLE || !sv || !sr || se || sa[1:0]!=0 || ((sa>>2)&((1<<LINE_WORD_BITS)-1))==((1<<LINE_WORD_BITS)-1) || sa+4>=ROM_BYTES)
            $fatal(1,"Invalid secondary I-cache response");
        if(second_data!==((sa+4)^32'ha5c35a7e))$fatal(1,"Secondary I-cache data mismatch");
        second_count=second_count+1;
    end
'''+marker)
        s=s.replace('$display("CACHE_UNIT_PASS', 'if(INSTRUCTION && ENABLE && second_count==0)$fatal(1,"No wide cache hit observed");\n        $display("WIDE_CACHE_PASS pairs=%0d",second_count);\n        $display("CACHE_UNIT_PASS')
    return s

def main():
    p=argparse.ArgumentParser(); p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--wide-fetch',action='store_true')
    p.add_argument('--fast-store',action='store_true')
    a=p.parse_args(); report=PROJECT/'reports'/('wide_cache_units' if a.wide_fetch else 'cache_units'); report.mkdir(parents=True,exist_ok=True)
    state={'status':'running','cases':[]}; manifest=report/'result.json'; manifest.write_text(json.dumps(state))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
    try:
        configs=[('d_default',0,1,5,2,1),('i_default',1,1,5,2,1),('d_small',0,1,1,2,1),('i_small',1,1,1,2,1),
                 ('d_disabled',0,0,5,2,1),('i_disabled',1,0,5,2,1),('d_word_fill',0,1,5,2,0),('i_word_fill',1,1,5,2,0),
                 ('d_line8',0,1,2,3,1),('i_line2',1,1,2,1,1)]
        for name,insn,enable,sb,lwb,bf in configs:
            cfg=dict(instruction=insn,enable=enable,set_bits=sb,line_word_bits=lwb,rom_bytes=32764 if 'line' in name else 32768,ram_bytes=32760 if 'line' in name else 32768,burst_transport=True,burst_fill=bf,wide_fetch=a.wide_fetch,fast_store=a.fast_store)
            build=PROJECT.parents[1]/'work/evolve5_cache_units'/('wide' if a.wide_fetch else 'scalar')/name; build.mkdir(parents=True,exist_ok=True)
            out=report/name; out.mkdir(exist_ok=True); facts=generate(build/'vectors.txt',cfg)
            (build/'tb_cache_unit.sv').write_text(testbench(cfg),encoding='utf-8')
            run_command([vb/'xvlog.bat','-sv',*sorted((PROJECT/'rtl/cache').glob('*.v')),PROJECT/'sim/burst_word_test_adapter.sv',build/'tb_cache_unit.sv'],build,out/'compile.log',env)
            run_command([vb/'xelab.bat','tb_cache_unit','-s','cache_unit'],build,out/'elaborate.log',env)
            output=run_command([vb/'xsim.bat','cache_unit','-runall'],build,out/'simulate.log',env)
            assert 'CACHE_UNIT_PASS' in output,output[-4000:]
            for n in ('vectors.txt','tb_cache_unit.sv'): shutil.copy2(build/n,out/n)
            state['cases'].append({'name':name,**facts,'vectors_sha256':hashlib.sha256((build/'vectors.txt').read_bytes()).hexdigest()})
            print('BURST_CACHE_PASS '+name,flush=True)
        state.update(status='passed',checked_utc=datetime.now(timezone.utc).isoformat(),hardware_tested=False)
        manifest.write_text(json.dumps(state,indent=2)); print('BURST_CACHE_UNITS_PASS')
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
