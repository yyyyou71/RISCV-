#!/bin/bash

# riscv64-unknown-elf-as asm/sum_1_10.asm -march=rv32i -mabi=ilp32 -o program/sum_1_10.o
# riscv64-unknown-elf-ld -m elf32lriscv -Ttext=0 -e _start -o program/sum_1_10.elf program/sum_1_10.o
# riscv64-unknown-elf-objcopy -O binary program/sum_1_10.elf program/sum_1_10.bin
# od -An -tx4 -v program/sum_1_10.bin | tr -s ' ' '\n' | grep . > program/sum_1_10.hex

# 用法: bash build.sh <输出文件> <源文件>
# 作用：把asm/sum_1_10.asm编译为hex

#=================================
#  $0            脚本自己的名字
#  $1 $2         第 1、第 2 个参数
#  $#            参数的个数
#  "$@"          所有参数
#=================================

set -e

if [ "$#" -lt 2 ] ;then
        echo "用法:bash $0 <输出文件> <源文件> [更多源文件...] " 
        exit 1
fi

OUT="$1"
shift 1
SRC="$@"

ELF="${OUT%.hex}.elf"
BIN="${OUT%.hex}.bin"
# %从右边（结尾）开始，删掉最短匹配的内容 #从左边（开头）开始，删掉最短匹配的内容
# %%从右边（结尾）开始，删掉最长匹配的内容  ##从左边（开头）开始，删掉最长匹配的内容。


echo "[1/4]编译+链接, ${SRC} ->  ${ELF}"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 \
        -ffreestanding -nostdlib -nostartfiles -Ttext=0 \
        -e _start -O1 -o "${ELF}" "$@"

echo "[2/4]提取裸字节, ${ELF}  ->  ${BIN}"
riscv64-unknown-elf-objcopy -O binary "${ELF}" "${BIN}"

echo "[3/4]转成 hex   ${BIN}  ->  ${OUT}"
od -An -tx4 -v "${BIN}" | tr -s ' ' '\n' | grep . > "${OUT}"

echo "finish!"

if [ -n "$KEEP" ]; then
    echo "[4/4] 保留中间文件"
else
    echo "[4/4] 清理中间文件 ${ELF} ${BIN}"
    rm -f "${ELF}" "${BIN}"
fi
