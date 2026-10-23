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

if [ "$#" -lt 3 ] ;then
        echo "用法:bash $0 <输出程序文件> <输出数据文件> <源文件> [更多源文件...] " 
        exit 1
fi

OUT="$1"
OUT_DATA="$2"
shift 2
SRC="$@"

ELF="${OUT%.hex}.elf"
BIN="${OUT%.hex}.bin"

BIN_DATA="${OUT_DATA%.hex}.bin"
# %从右边（结尾）开始，删掉最短匹配的内容 #从左边（开头）开始，删掉最短匹配的内容
# %%从右边（结尾）开始，删掉最长匹配的内容  ##从左边（开头）开始，删掉最长匹配的内容。

# -msmall-data-limit=0 表示关闭小数据优化。
# 开启小数据优化时：gp(x3) 指向小数据区（.sdata）的中间，
#   这样访问附近的全局变量只需一条 lw/sw offset(gp) 即可。
# 关闭小数据优化后：所有全局变量都不在 gp 的 ±2KB 范围内，
#   访问它们需要两条指令：先 lui 取高 20 位，再 addi/lw/sw 取低 12 位
echo "[1/4]编译+链接, ${SRC} ->  ${ELF}"
# GCC 10 尚不识别 Zmmul；用 M 扩展加 -mno-div 只生成硬件乘法。
# 关闭除法时显式链接 RV32I 的 libgcc，完整 M 扩展则使用 RV32IM 库。
LIB_ISA=rv32i
case "${ISA:-rv32i}" in
        rv32i) ISA_FLAGS=(-march=rv32i) ;;
        rv32i_zmmul) ISA_FLAGS=(-march=rv32im -mno-div) ;;
        rv32im) ISA_FLAGS=(-march=rv32im); LIB_ISA=rv32im ;;
        *) echo "不支持的 ISA：${ISA}，可选 rv32i / rv32i_zmmul / rv32im" >&2; exit 1 ;;
esac
LIBGCC_PATH=$(riscv64-unknown-elf-gcc "-march=${LIB_ISA}" -mabi=ilp32 -print-libgcc-file-name)
riscv64-unknown-elf-gcc "${ISA_FLAGS[@]}" -mabi=ilp32 -msmall-data-limit=0 \
        -ffreestanding -nostdlib -nostartfiles -T link.ld \
        -e _start -O1 -o "${ELF}" "$@" "${LIBGCC_PATH}"

echo "[2/4]提取裸字节, ${ELF}  ->  ${BIN}"
riscv64-unknown-elf-objcopy -j .text -O binary "${ELF}" "${BIN}" # -j .text的意思是只粘代码段
riscv64-unknown-elf-objcopy -j .data -O binary "${ELF}" "${BIN_DATA}"   # 数据 → 给 RAM

echo "[3/4]转成 hex   ${BIN}  ->  ${OUT}"
od -An -tx4 -v "${BIN}" | tr -s ' ' '\n' | grep . > "${OUT}"
# .data 为空是合法的（所有全局变量初值都是 0 → 被放进 .bss，不进 .data）。
# 此时 od 没有任何输出，grep 找不到行会返回退出码 1，
# 而 set -e 会把它当成「失败」并直接中止脚本 —— 于是后面的 finish! / [4/4] 全都不执行。
# || true 明确表示：空也是正常结果，不算失败。
od -An -tx1 -v "${BIN_DATA}" | tr -s ' ' '\n' | grep . > "${OUT_DATA}" || true

echo "finish!"

if [ -n "$KEEP" ]; then
    echo "[4/4] 保留中间文件，反汇编如下："
    riscv64-unknown-elf-objdump -d "${ELF}"
else
    echo "[4/4] 清理中间文件 ${ELF} ${BIN} ${BIN_DATA}"
    rm -f "${ELF}" "${BIN}" "${BIN_DATA}"
fi
