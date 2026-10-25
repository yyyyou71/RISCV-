"""Build reproducible upstream, directed and constrained-random test images."""
from collections import Counter
import json
from pathlib import Path
import struct
import subprocess

from reference import Model, MASK, MEM_SIZE, pack

RV32I_NAMES = set('lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl sra or and fence ecall ebreak'.split())


def r(f3, rd, a, b, f7=0):
    return f7 << 25 | b << 20 | a << 15 | f3 << 12 | rd << 7 | 0x33


def i(f3, rd, a, imm, op=0x13):
    return (imm & 4095) << 20 | a << 15 | f3 << 12 | rd << 7 | op


def s(f3, a, b, imm):
    v = imm & 4095
    return (v >> 5) << 25 | b << 20 | a << 15 | f3 << 12 | (v & 31) << 7 | 0x23


def b(f3, a, c, off):
    v = off & 8191
    return (v >> 12) << 31 | ((v >> 5) & 63) << 25 | c << 20 | a << 15 | f3 << 12 | ((v >> 1) & 15) << 8 | ((v >> 11) & 1) << 7 | 0x63


def j(rd, off):
    v = off & 0x1fffff
    return (v >> 20) << 31 | ((v >> 1) & 1023) << 21 | ((v >> 11) & 1) << 20 | ((v >> 12) & 255) << 12 | rd << 7 | 0x6f


def u(rd, imm):
    return imm << 12 | rd << 7 | 0x37


ECALL = 0x73
EBREAK = 0x100073
NOP = 0x13


def image(words, data=None):
    result = bytearray(struct.pack('<' + 'I' * len(words), *words))
    if data:
        for addr, payload in data.items():
            if len(result) < addr + len(payload):
                result.extend(bytes(addr + len(payload) - len(result)))
            result[addr:addr + len(payload)] = payload
    return bytes(result)


def directed():
    # Tuple: name, words, data, expected trap cause, explicitly known final registers.
    out = []

    def add(name, words, cause=11, regs=None, data=None):
        out.append((name, image(words, data), cause, regs or {}))

    add('smoke', [i(0,1,0,7),i(0,2,1,9),r(0,3,1,2),ECALL], regs={1:7,2:16,3:23})
    add('forward_priority', [i(0,1,0,1),i(0,1,1,1),i(0,1,1,1),r(0,2,1,1),r(0,3,2,1),ECALL], regs={1:3,2:6,3:9})
    add('x0_immutable', [i(0,0,0,-1),u(0,0xdeadb),i(0,1,0,5),r(0,0,1,1),r(0,2,0,1),ECALL], regs={0:0,1:5,2:5})
    add('load_use_and_store', [u(28,8),i(0,1,0,-17),s(2,28,1,0),i(2,2,28,0,3),r(0,3,2,2),s(2,28,3,4),i(2,4,28,4,3),ECALL], regs={2:MASK-16,3:MASK-33,4:MASK-33})
    add('held_wb_operand', [u(28,8),i(0,1,0,123),i(2,2,28,0,3),r(0,3,1,1),ECALL], regs={1:123,3:246}, data={0x8000:bytes.fromhex('11 22 33 44')})
    add('load_store_address', [u(28,8),i(2,1,28,0,3),i(0,2,0,77),s(2,1,2,0),i(2,3,1,0,3),ECALL], regs={1:0x8004,3:77}, data={0x8000:(0x8004).to_bytes(4,'little')})
    add('load_branch', [u(28,8),i(2,1,28,0,3),b(0,1,0,8),EBREAK,i(0,2,0,9),ECALL], regs={2:9}, data={0x8000:bytes(4)})
    add('load_jalr', [u(28,8),i(2,1,28,0,3),i(0,2,1,0,0x67),EBREAK,i(0,3,0,7),ECALL], regs={2:12,3:7}, data={0x8000:(16).to_bytes(4,'little')})
    add('jalr_lowbit_rd_rs1', [i(0,1,0,17),i(0,1,1,0,0x67),EBREAK,EBREAK,i(0,2,1,1),ECALL], regs={1:8,2:9})
    add('wrong_path_store_illegal', [u(28,8),i(0,1,0,7),b(0,1,1,16),s(2,28,1,0),0xffffffff,EBREAK,i(0,2,0,19),ECALL], regs={2:19})
    add('backward_loop', [i(0,1,0,31),i(0,2,0,0),r(0,2,2,1),i(0,1,1,-1),b(1,1,0,-8),ECALL], regs={1:0,2:496})
    add('byte_half_lanes', [u(28,8),i(0,1,0,-128),s(0,28,1,0),s(0,28,1,1),s(0,28,1,2),s(0,28,1,3),i(2,2,28,0,3),i(0,3,28,3,3),i(4,4,28,1,3),s(1,28,1,2),i(1,5,28,2,3),i(5,6,28,2,3),ECALL], regs={2:0x80808080,3:0xffffff80,4:128,5:0xffffff80,6:0xff80})
    add('fence_order', [u(28,8),i(0,1,0,27),s(2,28,1,0),0x0ff0000f,i(2,2,28,0,3),0x8330800f,ECALL], regs={2:27})
    add('not_taken_misaligned_target', [i(0,1,0,1),b(0,1,0,2),i(0,2,0,9),ECALL], regs={2:9})
    add('jal_misaligned', [i(0,1,0,9),j(1,2),s(2,0,1,0)], 0, {1:9})
    add('jalr_misaligned', [i(0,1,0,19),i(0,1,1,0,0x67),EBREAK], 0, {1:19})
    add('branch_misaligned', [b(0,0,0,2),EBREAK], 0)
    add('fetch_fault_after_jump', [u(1,15),i(0,2,1,0,0x67),EBREAK], 1, {2:8})
    for f3, label in [(1,'lh'),(2,'lw'),(5,'lhu')]:
        add('misaligned_'+label, [u(28,8),i(f3,1,28,1,3),s(2,28,1,0)], 4)
    for f3, label in [(1,'sh'),(2,'sw')]:
        add('misaligned_'+label, [u(28,8),i(0,1,0,7),s(f3,28,1,1),s(2,28,1,4)], 6)
    for f3, label in [(0,'lb'),(1,'lh'),(2,'lw'),(4,'lbu'),(5,'lhu')]:
        add('access_fault_'+label, [u(28,15),i(f3,1,28,0,3),s(2,0,1,0)], 5)
    for f3, label in [(0,'sb'),(1,'sh'),(2,'sw')]:
        add('access_fault_'+label, [u(28,15),i(0,1,0,7),s(f3,28,1,0),s(2,0,1,0)], 7)
    add('load_x0_still_faults', [u(28,15),i(2,0,28,0,3),EBREAK], 5)
    add('address_wrap', [i(0,1,0,-4),i(2,2,1,4,3),ECALL], regs={2:i(0,1,0,-4)})
    add('older_load_fault_beats_younger_ecall', [u(28,15),i(2,1,28,0,3),ECALL,s(2,0,1,0)], 5)
    add('older_store_before_trap', [u(28,8),i(0,1,0,55),s(2,28,1,0),EBREAK,s(2,28,0,0)], 3, {1:55})
    add('ecall_precise', [i(0,1,0,44),ECALL,i(0,1,0,99),s(2,0,1,0)], 11, {1:44})
    add('ebreak_precise', [i(0,1,0,44),EBREAK,i(0,1,0,99),s(2,0,1,0)], 3, {1:44})
    illegal = {
        'all_ones':0xffffffff, 'zero':0, 'compressed':0x00000001,
        'mul':r(0,1,2,3,1), 'invalid_add_f7':r(0,1,2,3,2),
        'invalid_sll_f7':r(1,1,2,3,32), 'slli_reserved':i(1,1,2,32),
        'srli_reserved':i(5,1,2,0x800), 'invalid_load':i(3,1,2,0,3),
        'invalid_store':s(3,2,1,0), 'invalid_branch':b(2,0,0,4),
        'invalid_jalr':i(1,1,0,0,0x67), 'fence_i':0x0000100f,
        'unknown_csr':0x7ff110f3, 'malformed_mret':0x302000f3, 'malformed_ecall':0x000000f3,
    }
    for label, insn in illegal.items():
        add('illegal_'+label, [i(0,1,0,77),insn,i(0,1,0,88),s(2,0,1,0)], 2, {1:77})
    add('reset_inflight', [u(28,8),i(0,1,0,123),s(2,28,1,0),i(2,2,28,0,3),ECALL], regs={1:123,2:123})
    return out


class LCG:
    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (1664525 * self.state + 1013904223) & MASK
        return self.state

    def choose(self, values):
        return values[(self.next() >> 12) % len(values)]


def random_image(seed, count=1800):
    rng = LCG(seed)
    words = [u(28,8)]
    edges = [0,1,31,32,33,0x7fffffff,0x80000000,0xffffffff,0xdeadbeef]
    for rd in range(1,28):
        v = rng.choose(edges) if rd & 1 else rng.next()
        upper = ((v + 0x800) >> 12) & 0xfffff
        words.extend([u(rd,upper),i(0,rd,rd,v & 4095)])
    for _ in range(count):
        rd, a, c = (rng.choose(list(range(28))) for _ in range(3))
        kind = rng.choose(list(range(12)))
        if kind < 4:
            f3 = rng.choose(list(range(8)))
            f7 = rng.choose([0,32]) if f3 in (0,5) else 0
            words.append(r(f3,rd,a,c,f7))
        elif kind < 7:
            f3 = rng.choose(list(range(8)))
            imm = rng.next() & 4095
            if f3 == 1: imm &= 31
            if f3 == 5: imm = (imm & 31) | rng.choose([0,0x400])
            words.append(i(f3,rd,a,imm))
        elif kind == 7:
            f3 = rng.choose([0,1,2,4,5]); size = 1 << (f3 & 3)
            off = ((rng.next() >> 10) % 256) & ~(size-1)
            words.append(i(f3,rd,28,off,3))
        elif kind == 8:
            f3 = rng.choose([0,1,2]); size = 1 << f3
            off = ((rng.next() >> 10) % 256) & ~(size-1)
            words.append(s(f3,28,c,off))
        elif kind == 9:
            words.extend([b(rng.choose([0,1,4,5,6,7]),a,c,8),i(0,rd,rd,1)])
        elif kind == 10:
            words.extend([j(rd,8),s(2,28,a,256)])  # store must be squashed
        else:
            words.append(u(rd,rng.next() & 0xfffff) if rng.next() & 1 else 0x0ff0000f)
    words.append(ECALL)
    payload = bytes((rng.next() >> 16) & 255 for _ in range(512))
    return image(words,{0x8000:payload})


def write_image(path, binary):
    # Sparse byte-addressed readmemh format; unspecified bytes initialize to zero.
    chunks = []
    for start in range(0,len(binary),256):
        chunk = binary[start:start+256]
        if any(chunk):
            chunks.append(f'@{start:08x}\n'+'\n'.join(f'{v:02x}' for v in chunk))
    path.write_text('\n'.join(chunks)+'\n',encoding='ascii')


def generate(project, build, gcc, suite, seeds):
    cases = []
    bins = build/'cases'
    bins.mkdir(parents=True,exist_ok=True)
    coverage = Counter()
    metadata = []

    def record(name,binary,cause=11,regs=None,upstream=False):
        model = Model(binary)
        trace = model.run()
        # CPU now enters M-mode handler; reference stops at that first exception.
        trace[-1]['next_pc']=0xe000
        if trace[-1]['cause'] != cause:
            raise AssertionError(f'{name}: expected cause {cause}, got {trace[-1]}')
        if upstream and model.reg[3] != 1:
            raise AssertionError(f'{name}: upstream self-check failed, x3={model.reg[3]}')
        for reg,val in (regs or {}).items():
            if model.reg[reg] != (val & MASK):
                raise AssertionError(f'{name}: reference x{reg}={model.reg[reg]:08x}, expected {val & MASK:08x}')
        coverage.update(model.coverage)
        memfile = bins/(name+'.hex')
        tracefile = bins/(name+'.gold')
        write_image(memfile,binary)
        tracefile.write_text('\n'.join(pack(x) for x in trace)+'\n',encoding='ascii')
        profiles = [(0,0),(1,1),(2,2),(0,3)]
        if name == 'reset_inflight': profiles = [(0,3)]
        if suite == 'smoke': profiles = [(0,0),(2,2),(0,3)]
        for imode,dmode in profiles:
            cname = f'{name}__i{imode}d{dmode}'
            # Relative paths have no spaces; manifest is interpreted in build cwd.
            cases.append(f'{cname} cases/{name}.hex cases/{name}.gold {len(trace)} {imode} {dmode} 20260921 {int(name == "reset_inflight")}')
        metadata.append({'name':name,'packets':len(trace),'cause':cause,'upstream':upstream,'image_bytes':len(binary)})

    for name,binary,cause,regs in directed():
        if suite == 'smoke' and name not in ('smoke','forward_priority','load_use_and_store','held_wb_operand','wrong_path_store_illegal','ecall_precise'):
            continue
        record(name,binary,cause,regs)

    excluded = {'fence_i':'Zifencei is outside this core configuration',
                'ma_data':'This EEI traps misaligned data accesses; directed trap tests cover that contract'}
    if suite == 'all':
        vendor = project/'third_party'/'riscv-tests'
        env = project/'tests'/'env'
        for source in sorted((vendor/'isa'/'rv32ui').glob('*.S')):
            if source.stem in excluded: continue
            elf = bins/('upstream_'+source.stem+'.elf')
            cmd = [str(gcc),'-march=rv32i','-mabi=ilp32','-mno-relax','-nostdlib','-nostartfiles',
                   '-I'+str(env),'-I'+str(vendor/'isa'/'macros'/'scalar'),
                   '-Wl,--no-relax','-T',str(env/'link.ld'),str(source),'-o',str(elf)]
            cp = subprocess.run(cmd,capture_output=True,text=True,errors='replace')
            (bins/(elf.stem+'.compile.log')).write_text(cp.stdout+cp.stderr,encoding='utf-8')
            if cp.returncode: raise RuntimeError(f'Compile failed: {source.name}\n{cp.stdout}{cp.stderr}')
            binfile = elf.with_suffix('.bin')
            objcopy = str(gcc).replace('gcc.exe','objcopy.exe')
            objdump = str(gcc).replace('gcc.exe','objdump.exe')
            subprocess.run([objcopy,'-O','binary',str(elf),str(binfile)],check=True,capture_output=True)
            disasm = subprocess.run([objdump,'-d',str(elf)],check=True,capture_output=True,text=True).stdout
            elf.with_suffix('.dis').write_text(disasm,encoding='utf-8')
            record('upstream_'+source.stem,binfile.read_bytes(),upstream=True)
        for seed in range(seeds):
            record(f'random_{seed:03d}',random_image(0xA0120000+seed))
        missing = RV32I_NAMES - set(coverage)
        if missing: raise AssertionError(f'Instruction coverage missing: {sorted(missing)}')

    (build/'manifest.txt').write_text('\n'.join(cases)+'\n',encoding='ascii')
    info = {'suite':suite,'programs':metadata,'simulation_cases':len(cases),'instruction_coverage':dict(sorted(coverage.items())),
            'excluded_upstream':excluded,'random_seeds':seeds if suite == 'all' else 0,'rv32i_instruction_kinds':len(RV32I_NAMES & set(coverage))}
    (build/'generation.json').write_text(json.dumps(info,indent=2),encoding='utf-8')
    return info
