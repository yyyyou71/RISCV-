// Local bare-metal harness for UNMODIFIED upstream RV32UI test bodies.
// No privileged setup. x3=1 + ECALL means PASS; x3=(testnum<<1)|1 means FAIL.
#ifndef RV32_PROJECT_TEST_H
#define RV32_PROJECT_TEST_H
#define RVTEST_RV32U
#define RVTEST_RV64U
#define TESTNUM gp
#define RVTEST_CODE_BEGIN .section .text.init; .balign 4; .globl _start; _start:
#define RVTEST_CODE_END
#define RVTEST_DATA_BEGIN .balign 16; .global begin_signature; begin_signature:
#define RVTEST_DATA_END .balign 16; .global end_signature; end_signature:
#define RVTEST_PASS li TESTNUM, 1; ecall
#define RVTEST_FAIL sll TESTNUM, TESTNUM, 1; or TESTNUM, TESTNUM, 1; ecall
#endif
