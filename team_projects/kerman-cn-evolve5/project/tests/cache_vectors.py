"""Independent transaction-level cache/reference-memory oracle; deterministic replay."""
import random
MASK=0xffffffff
RAM=0x20000000
MMIO=0x40000000

class Oracle:
    def __init__(self,cfg):
        self.cfg=cfg; self.sets=1<<cfg['set_bits']; self.words=1<<cfg['line_word_bits']
        self.lines=[[] for _ in range(self.sets)]; self.ram={}; self.mmio=0; self.time=0
    def reset(self): self.lines=[[] for _ in range(self.sets)]
    def value(self,addr): return self.ram.get(addr,addr^0xa5c35a7e)
    def backend(self,addr,write,data,mask,fault,fault_write):
        a=addr&~3; c=self.cfg
        rom=a<c['rom_bytes']; ram=RAM<=a<RAM+c['ram_bytes']
        legal=(rom and not write) if c['instruction'] else ((rom and not write) or ram or a==MMIO)
        if not legal or (a==fault and write==fault_write): return 1,0
        if write:
            if ram:
                old=self.value(a)
                for lane in range(4):
                    if mask>>lane&1: old=(old&~(255<<(lane*8)))|(data&(255<<(lane*8)))
                self.ram[a]=old
            return 0,0
        if a==MMIO:
            self.mmio+=1; return 0,self.mmio
        return 0,self.value(a)
    def access(self,addr,write,data,mask,fault,fault_write):
        c=self.cfg; base=addr&~(self.words*4-1); end=base+self.words*4
        rom=addr<c['rom_bytes'] and end<=c['rom_bytes']
        ram=RAM<=base<=addr<RAM+c['ram_bytes'] and end<=RAM+c['ram_bytes']
        eligible=c['enable'] and ((not write and addr%4==0 and rom) if c['instruction'] else (ram if write else rom or ram))
        group=self.lines[(base//(self.words*4))%self.sets]
        hit=next((entry for entry in group if entry['base']==base),None)
        self.time+=1
        if not eligible:
            err,value=self.backend(addr,write,data,mask,fault,fault_write); return err,value,1
        if write:
            err,value=self.backend(addr,write,data,mask,fault,fault_write)
            if hit:
                if err: group.remove(hit)
                else: hit['data'][addr&~3]=self.value(addr&~3); hit['age']=self.time
            return err,value,1
        if hit:
            hit['age']=self.time; return 0,hit['data'][addr&~3],0
        if len(group)==2: group.remove(min(group,key=lambda e:e['age']))
        new={}; transactions=0
        if c.get('burst_transport'):
            failed=False; demand_failed=False
            for a in range(base,end,4):
                err,value=self.backend(a,False,0,0,fault,fault_write); transactions+=1
                failed=failed or err; demand_failed=demand_failed or (err and a==(addr&~3)); new[a]=value
            if demand_failed: return 1,0,transactions
            if failed:
                err,value=self.backend(addr,False,0,0,fault,fault_write)
                return err,value,transactions+1
            group.append({'base':base,'age':self.time,'data':new})
            return 0,new[addr&~3],transactions
        for a in range(base,end,4):
            err,value=self.backend(a,False,0,0,fault,fault_write); transactions+=1
            if err:
                if a==addr&~3: return 1,0,transactions
                err,value=self.backend(addr,False,0,0,fault,fault_write)
                return err,value,transactions+1
            new[a]=value
        group.append({'base':base,'age':self.time,'data':new})
        return 0,new[addr&~3],transactions

def generate(path,cfg):
    model=Oracle(cfg); vectors=[]; groups=[]; nofault=MASK; stride=(1<<cfg['set_bits'])*(4<<cfg['line_word_bits'])
    def access(addr,write=0,data=0,mask=15,fault=nofault,fault_write=0,delay=2):
        err,value,count=model.access(addr,write,data,mask,fault,fault_write)
        vectors.append((int(write),addr,data,mask,err,value,count,fault,fault_write,delay))
    def reset(op=2,addr=0):
        model.reset(); vectors.append((op,addr,0x87654321,15,0,0,1 if op==3 else 0,nofault,0,3))
    def group(name): groups.append(name)
    base=0 if cfg['instruction'] else RAM
    group('cold_line_and_all_word_hits'); reset()
    access(base)
    for word in range(1<<cfg['line_word_bits']): access(base+word*4,delay=0)
    group('two_ways_and_lru'); reset()
    for offset in (0,stride,0,2*stride,0,stride): access(base+offset)
    group('line_and_region_boundaries')
    for a in (cfg['rom_bytes']-4,cfg['rom_bytes']-4,cfg['rom_bytes'],RAM+cfg['ram_bytes']-4,RAM+cfg['ram_bytes']-4,RAM+cfg['ram_bytes'],0xfffffffc): access(a)
    group('uncached_mmio_exactly_once')
    for _ in range(4): access(MMIO)
    if not cfg['instruction']:
        access(MMIO,1,0x12345678); access(MMIO)
        group('write_no_allocate_and_byte_masks'); reset()
        access(RAM+0x100,1,0x12345678); access(RAM+0x100); access(RAM+0x100)
        for mask in range(16):
            access(RAM+0x100+(mask%4),1,0x01234567^(mask*0x10101010),mask)
            access(RAM+0x100+(mask%4))
        group('rom_write_protection'); access(0); access(0,1,0,15); access(0)
        group('failed_write_invalidates_hit'); reset(); access(RAM)
        access(RAM,1,0,15,fault=RAM,fault_write=1); access(RAM); access(RAM)
    group('demand_and_neighbour_fill_errors')
    for demand in (0,(1<<cfg['line_word_bits'])-1):
        for fault in range(1<<cfg['line_word_bits']):
            reset(); access(base+demand*4,fault=base+fault*4)
            access(base+demand*4); access(base+demand*4)
    if cfg['enable']:
        group('reset_during_partial_fill'); reset(); reset(3,base+0x200); access(base+0x200); access(base+0x200)
    if not cfg['instruction']:
        group('reset_cancels_uncompleted_write'); reset(4,RAM+0x400); access(RAM+0x400)
    group('reset_invalidates_cached_lines'); reset(); access(base); access(base); reset(); access(base)
    group('deterministic_random_reference_memory')
    rng=random.Random(20261001+int(cfg['instruction']))
    for i in range(1200):
        if i%101==0: reset()
        # Concentrate conflict accesses but also cover both regions and bypass.
        a=base+rng.randrange(0,16)*stride+rng.randrange(0,1<<cfg['line_word_bits'])*4
        if i%17==0: a=MMIO
        if i%29==0: a=0x50000000
        if i%37==0: a=0x7ff8
        write=not cfg['instruction'] and rng.randrange(3)==0
        access(a,write,rng.getrandbits(32),rng.randrange(16),delay=i%4)
    lines=[]
    for op,a,d,m,e,v,n,f,w,delay in vectors:
        line=f'{op} {a:08x} {d:08x} {m:x} {e} {v:08x} {n} {f:08x} {w} {delay}'
        if cfg.get('burst_transport'):
            commands=0 if op==2 else 1 if op in (3,4) else n if n<=1 or not cfg['burst_fill'] else 1+int(n>model.words)
            line+=f' {commands}'
        lines.append(line+'\n')
    path.write_text(''.join(lines),encoding='ascii')
    return {'vectors':len(vectors),'groups':groups,'reference':'Independent Python LRU transaction model and byte-mask backing memory','configuration':cfg}
