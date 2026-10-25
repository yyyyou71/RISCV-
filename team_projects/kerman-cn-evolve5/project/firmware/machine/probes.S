.option norvc
.option norelax
.section .text.probe_ecall,"ax",@progbits
.balign 4
.globl probe_ecall, probe_ecall_fault, probe_ecall_resume
.type probe_ecall,@function
probe_ecall:
probe_ecall_fault:
ecall
probe_ecall_resume:
ret
.size probe_ecall,.-probe_ecall
.section .text.probe_ebreak,"ax",@progbits
.balign 4
.globl probe_ebreak, probe_ebreak_fault, probe_ebreak_resume
.type probe_ebreak,@function
probe_ebreak:
probe_ebreak_fault:
ebreak
probe_ebreak_resume:
ret
.size probe_ebreak,.-probe_ebreak
.section .text.probe_illegal,"ax",@progbits
.balign 4
.globl probe_illegal, probe_illegal_fault, probe_illegal_resume
.type probe_illegal,@function
probe_illegal:
probe_illegal_fault:
.word 0xffffffff
probe_illegal_resume:
ret
.size probe_illegal,.-probe_illegal
.section .text.probe_misaligned_load,"ax",@progbits
.balign 4
.globl probe_misaligned_load, probe_misaligned_load_fault, probe_misaligned_load_resume
.type probe_misaligned_load,@function
probe_misaligned_load:
probe_misaligned_load_fault:
lw a0,1(zero)
probe_misaligned_load_resume:
ret
.size probe_misaligned_load,.-probe_misaligned_load
.section .text.probe_misaligned_store,"ax",@progbits
.balign 4
.globl probe_misaligned_store, probe_misaligned_store_fault, probe_misaligned_store_resume
.type probe_misaligned_store,@function
probe_misaligned_store:
probe_misaligned_store_fault:
sw a0,1(zero)
probe_misaligned_store_resume:
ret
.size probe_misaligned_store,.-probe_misaligned_store
.section .text.probe_load_access,"ax",@progbits
.balign 4
.globl probe_load_access, probe_load_access_fault, probe_load_access_resume
.type probe_load_access,@function
probe_load_access:
lui t0,0x50000
probe_load_access_fault:
lw a0,0(t0)
probe_load_access_resume:
ret
.size probe_load_access,.-probe_load_access
.section .text.probe_rom_write,"ax",@progbits
.balign 4
.globl probe_rom_write, probe_rom_write_fault, probe_rom_write_resume
.type probe_rom_write,@function
probe_rom_write:
probe_rom_write_fault:
sw zero,0(zero)
probe_rom_write_resume:
ret
.size probe_rom_write,.-probe_rom_write
.section .text.probe_unknown_csr,"ax",@progbits
.balign 4
.globl probe_unknown_csr, probe_unknown_csr_fault, probe_unknown_csr_resume
.type probe_unknown_csr,@function
probe_unknown_csr:
probe_unknown_csr_fault:
csrr a0,0x7ff
probe_unknown_csr_resume:
ret
.size probe_unknown_csr,.-probe_unknown_csr
.section .text.probe_readonly_csr,"ax",@progbits
.balign 4
.globl probe_readonly_csr, probe_readonly_csr_fault, probe_readonly_csr_resume
.type probe_readonly_csr,@function
probe_readonly_csr:
probe_readonly_csr_fault:
csrrw zero,mvendorid,zero
probe_readonly_csr_resume:
ret
.size probe_readonly_csr,.-probe_readonly_csr
.section .text.probe_misaligned_jump,"ax",@progbits
.balign 4
.globl probe_misaligned_jump, probe_misaligned_jump_fault, probe_misaligned_jump_resume
.type probe_misaligned_jump,@function
probe_misaligned_jump:
probe_misaligned_jump_fault:
jalr zero,2(zero)
probe_misaligned_jump_resume:
ret
.size probe_misaligned_jump,.-probe_misaligned_jump
.section .text.probe_fetch_access,"ax",@progbits
.balign 4
.globl probe_fetch_access, probe_fetch_access_fault, probe_fetch_access_resume
.type probe_fetch_access,@function
probe_fetch_access:
lui t0,0x50000
probe_fetch_access_fault:
jalr zero,0(t0)
probe_fetch_access_resume:
ret
.size probe_fetch_access,.-probe_fetch_access
