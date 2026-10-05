addi x1,x0,0
addi x2,x0,0
addi x3,x0,10

addi x2,x2,1
add x1,x1,x2
addi x3,x3,-1
bne x0,x3,-12
jal x0,0