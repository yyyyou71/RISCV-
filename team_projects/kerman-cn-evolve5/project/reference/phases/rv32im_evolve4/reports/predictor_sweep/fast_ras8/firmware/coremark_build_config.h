#ifndef COREMARK_BUILD_CONFIG_H
#define COREMARK_BUILD_CONFIG_H
#define COREMARK_DEFAULT_ITERATIONS 2048u
#define COREMARK_BUILD_ID "EVOLVE1_BOARD"
#define COREMARK_NATIVE_M 1
#define COREMARK_SOFTWARE_ISA "RV32IM_Zicsr"
#define COREMARK_FLAGS_TEXT "-march=rv32im_zicsr2p0 -mabi=ilp32 -mcmodel=medlow -mno-relax -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-strict-aliasing -fno-pic -fno-stack-protector -fno-common -fno-asynchronous-unwind-tables -fno-unwind-tables -ffunction-sections -fdata-sections -fno-tree-loop-distribute-patterns -Wall -Wextra -Werror -std=gnu11 -g -O2 -DSOC_CLOCK_HZ=25000000u -DSOC_UART_BAUD=115200u -flto; link: -nostdlib --gc-sections --no-relax"
#endif
