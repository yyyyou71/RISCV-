from machine_programs import HEAD,END,expect
def programs(config):
    out=[]
    setup=HEAD+'''la t0,handler
csrw mtvec,t0
li s0,0
'''
    body=setup+'''li t0,128
csrw mie,t0
csrsi mstatus,8
.balign 16
csrr s4,0xfc3
pair_start:
addi a0,zero,17
addi a1,zero,29
after_pair:
csrr t5,0xfc3
sub t5,t5,s4
'''+expect('t5',1)+expect('a0',17)+expect('a1',29)+expect('s0',1)+'''j pass
handler:
csrr t0,mcause
li t1,0x80000007
bne t0,t1,fail
csrr t0,mepc
la t1,after_pair
bne t0,t1,fail
li t1,17
bne a0,t1,fail
li t1,29
bne a1,t1,fail
addi s0,s0,1
csrwi mie,0
mret
'''+END
    out.append(dict(name='dual_irq_after_ordered_pair',asm=body,scene=21,irq=1,trap=0,profiles=[(0,0),(1,1),(2,2),(0,3)]))
    for scene,insn,cause in [(22,'lw a0,0(s1)',5),(23,'sw a0,0(s1)',7)]:
        body=setup+'''li s1,0xf000
li s2,85
li a0,12
csrr s3,0xfc2
.balign 16
csrr s4,0xfc3
fault:
'''+insn+'''
addi s2,zero,99
resume:
mv t5,s5
sub t5,t5,s4
'''+expect('t5',0)+expect('s2',85)+expect('a0',12)+expect('s0',1)+'''j pass
handler:
csrr s5,0xfc3
csrr t0,mcause
'''+expect('t0',cause)+'''csrr t0,mepc
la t1,fault
bne t0,t1,fail
csrr t0,mtval
'''+expect('t0',0xf000)+'''addi s0,s0,1
la t0,resume
csrw mepc,t0
mret
'''+END
        # Sample immediately at trap entry. Legitimate pairing inside the ISR
        # must not be mistaken for retirement of the faulting group's slot1.
        out.append(dict(name=f'dual_older_fault_{cause}_suppresses_alu',asm=body,scene=scene,irq=0,trap=1,profiles=[(0,0),(1,1),(2,2),(0,3)]))
    return out

def extend_tb(source):
    source=source.replace('    rv32_core', '    wire retire2;wire [31:0] npc2;\n    rv32_core',1)
    source=source.replace('.retire_valid(retire),', '.retire2_valid(retire2),.retire2_next_pc(npc2),.retire_valid(retire),')
    source=source.replace('            if(irq_taken) begin\n                #1;', '            if(retire2) begin\n                if(!retire || exception)$fatal(1,"Invalid second retirement in machine test");\n                last_next=npc2;\n            end\n            if(irq_taken) begin\n                #1;')
    marker="if(scene==6 && !started && dut.x_valid"
    insert="""if(scene==21 && !started && dut.x_valid && dut.x2_valid && dut.x_insn==32'h01100513 && dut.x2_insn==32'h01d00593) begin
                started=1;irq_timer<=1;
            end else if((scene==22 || scene==23) && !started && dut.x_valid && dut.x2_valid && (dut.x_load || dut.x_store) && dut.x2_insn==32'h06300913) begin
                started=1;
            end else if(scene==6 && !started && dut.x_valid"""
    assert source.count(marker)==1
    return source.replace(marker,insert)
