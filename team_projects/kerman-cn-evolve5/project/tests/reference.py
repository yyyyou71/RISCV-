"""Instruction-at-a-time RV32I EEI model; intentionally no pipeline logic.

This is a project reference, not Spike or an ISA certification oracle. Upstream
riscv-tests also validate their own expected values in the guest program.
The simulator and this model share only the documented bus/EEI contract.
"""
from collections import Counter

MASK = 0xFFFFFFFF
MEM_SIZE = 65536
FAULT_BASE = 0xF000
FIELDS = ('pc', 'insn', 'next_pc', 'rd_we', 'rd', 'rd_data', 'mem_addr',
          'wmask', 'wdata', 'rmask', 'rdata', 'trap', 'cause', 'tval')


def sext(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def pack(record):
    return ''.join(f'{record[k] & MASK:08x}' for k in FIELDS)


class Model:
    def __init__(self, image, pc=0):
        self.mem = bytearray(MEM_SIZE)
        self.mem[:len(image)] = image
        self.reg = [0] * 32
        self.pc = pc
        self.halted = False
        self.coverage = Counter()

    def word(self, addr):
        return int.from_bytes(self.mem[addr:addr + 4], 'little')

    def step(self):
        pc = self.pc
        rec = dict.fromkeys(FIELDS, 0)
        rec['pc'] = pc
        rec['next_pc'] = (pc + 4) & MASK

        def trap(cause, tval, mnemonic):
            rec.update(next_pc=pc, trap=1, cause=cause, tval=tval & MASK,
                       rd_we=0, rd=0, rd_data=0, mem_addr=0, wmask=0,
                       wdata=0, rmask=0, rdata=0)
            self.coverage[mnemonic] += 1
            self.halted = True
            return rec

        if pc & 3:
            return trap(0, pc, 'instruction_misaligned')
        if pc >= FAULT_BASE:
            return trap(1, pc, 'instruction_access_fault')
        insn = self.word(pc)
        rec['insn'] = insn
        op = insn & 127
        rd, a, b = (insn >> 7) & 31, (insn >> 15) & 31, (insn >> 20) & 31
        f3, f7 = (insn >> 12) & 7, insn >> 25
        av, bv = self.reg[a], self.reg[b]
        imm = sext(insn >> 20, 12)
        result = None
        name = None
        if op in (0x37, 0x17):
            name = 'lui' if op == 0x37 else 'auipc'
            result = (insn & 0xfffff000) + (pc if op == 0x17 else 0)
        elif op in (0x6f, 0x67):
            if op == 0x6f:
                off = ((insn >> 31) << 20) | (insn & 0xff000) | ((insn >> 20 & 1) << 11) | ((insn >> 21 & 1023) << 1)
                target = (pc + sext(off, 21)) & MASK
                name = 'jal'
            else:
                if f3 != 0:
                    return trap(2, insn, 'illegal')
                target = ((av + imm) & MASK) & ~1
                name = 'jalr'
            if target & 3:
                return trap(0, target, 'instruction_misaligned')
            result = pc + 4
            rec['next_pc'] = target
        elif op == 0x63:
            comparisons = {
                0: ('beq', av == bv), 1: ('bne', av != bv),
                4: ('blt', sext(av, 32) < sext(bv, 32)),
                5: ('bge', sext(av, 32) >= sext(bv, 32)),
                6: ('bltu', av < bv), 7: ('bgeu', av >= bv),
            }
            if f3 not in comparisons:
                return trap(2, insn, 'illegal')
            name, taken = comparisons[f3]
            self.coverage['branch_taken' if taken else 'branch_not_taken'] += 1
            if taken:
                off = ((insn >> 31) << 12) | ((insn >> 7 & 1) << 11) | ((insn >> 25 & 63) << 5) | ((insn >> 8 & 15) << 1)
                target = (pc + sext(off, 13)) & MASK
                if target & 3:
                    return trap(0, target, 'instruction_misaligned')
                rec['next_pc'] = target
        elif op in (0x03, 0x23):
            store = op == 0x23
            legal = (0, 1, 2) if store else (0, 1, 2, 4, 5)
            if f3 not in legal:
                return trap(2, insn, 'illegal')
            if store:
                imm = sext(((insn >> 25) << 5) | ((insn >> 7) & 31), 12)
            size = 1 << (f3 & 3)
            addr = (av + imm) & MASK
            if addr % size:
                return trap(6 if store else 4, addr, 'store_misaligned' if store else 'load_misaligned')
            if addr >= FAULT_BASE:
                return trap(7 if store else 5, addr, 'store_access_fault' if store else 'load_access_fault')
            mask = ((1 << size) - 1) << (addr & 3)
            rec['mem_addr'] = addr
            if store:
                name = {0: 'sb', 1: 'sh', 2: 'sw'}[f3]
                value = bv & ((1 << (8 * size)) - 1)
                self.mem[addr:addr + size] = value.to_bytes(size, 'little')
                rec.update(wmask=mask, wdata=value << (8 * (addr & 3)))
            else:
                name = {0: 'lb', 1: 'lh', 2: 'lw', 4: 'lbu', 5: 'lhu'}[f3]
                value = int.from_bytes(self.mem[addr:addr + size], 'little')
                result = sext(value, 8 * size) if f3 < 4 else value
                rec.update(rmask=mask, rdata=self.word(addr & ~3))
        elif op in (0x13, 0x33):
            immediate = op == 0x13
            v = imm & MASK if immediate else bv
            shift = v & 31
            if immediate:
                if (f3 == 1 and f7 != 0) or (f3 == 5 and f7 not in (0, 32)):
                    return trap(2, insn, 'illegal')
            elif f7 != 0 and not (f7 == 32 and f3 in (0, 5)):
                return trap(2, insn, 'illegal')
            if f3 == 0:
                sub = not immediate and f7 == 32
                name, result = ('sub', av - v) if sub else ('add', av + v)
            elif f3 == 1:
                name, result = 'sll', av << shift
            elif f3 == 2:
                name, result = 'slt', int(sext(av, 32) < sext(v, 32))
            elif f3 == 3:
                name, result = 'sltu', int(av < v)
            elif f3 == 4:
                name, result = 'xor', av ^ v
            elif f3 == 5:
                name, result = ('sra', sext(av, 32) >> shift) if f7 == 32 else ('srl', av >> shift)
            elif f3 == 6:
                name, result = 'or', av | v
            elif f3 == 7:
                name, result = 'and', av & v
            if immediate:
                name = {'sltu': 'sltiu'}.get(name, name + 'i')
        elif op == 0x0f and f3 == 0:
            name = 'fence'
        elif insn == 0x00000073:
            return trap(11, 0, 'ecall')
        elif insn == 0x00100073:
            return trap(3, pc, 'ebreak')
        else:
            return trap(2, insn, 'illegal')
        if result is not None and rd:
            self.reg[rd] = result & MASK
            rec.update(rd_we=1, rd=rd, rd_data=result & MASK)
        self.reg[0] = 0
        self.pc = rec['next_pc']
        self.coverage[name] += 1
        return rec

    def run(self, limit=100000):
        trace = []
        while not self.halted:
            if len(trace) >= limit:
                raise RuntimeError(f'Reference timeout at PC={self.pc:08x}')
            trace.append(self.step())
        return trace
