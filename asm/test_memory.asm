#==========================================================
# 本程序用于测试处理器的内存
# 实现方式同样是1-10的数列求和，不过会添加读取/写入内存的动作
#==========================================================

        .text
        .globl _start

_start:
        addi x1, x0, 0          # sum = 0
        addi x2, x0, 0          # i   = 0
        addi x3, x0, 10         # n   = 10
        addi x4, x0, 0
        addi x31,x0, 0

store:
        addi x2, x2, 1
        sb x2,0(x2)             #x2同时是数据和地址
        addi x3,x3,-1
        bne x0,x3,store

        addi x3, x0, 10         # n   = 10
sum:    
        addi x4, x4, 1
        lb x2, 0(x4)
        add x1, x1, x2
        addi x3,x3,-1
        bne x0,x3,sum

        addi x5,x0,55
        bne x5, x1 ,halt
        addi x31,x0,1

halt:
        jal x0, halt


        # .text
        # .globl _start
# ./tools/build.sh ./asm/test_memory.asm ./program/test_memory.hex
# sb rs2, offset(rs1)
# lb rd, offset(rs1)
# _start:
#         addi x1,x0,1
#         sb x1,0(x1)
#         lb x1,0(x1)
#         addi x2,x0,2
#         sb x2,0(x2)
#         lb x2,0(x2)
#         addi x3,x0,3
#         sb x3,0(x3)
#         lb x3,0(x3)
#         addi x4,x0,4
#         sb x4,0(x4)
#         lb x4,0(x4)

# halt:
#         jal x0, halt