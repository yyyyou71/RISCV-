#!/usr/bin/env bash
# ==========================================================================
# build.sh —— 把 RISC-V 汇编(.s) 或 C(.c) 编译成 $readmemh 能读的 hex
#
# 用法:
#     ./tools/build.sh <源文件> <输出.hex>
# 例如:
#     ./tools/build.sh asm/sum_1_10.asm program/sum_1_10.hex
#
# 它做的事 = 下面 4 步，只是帮你记参数、排顺序、出错就停:
#     [1] gcc     源文件   -> .elf   (汇编/编译 + 链接，算出所有跳转偏移)
#     [2] objcopy .elf     -> .bin   (剥掉 ELF 文件头，只留裸字节)
#     [3] od      .bin     -> .hex   (每 4 字节按小端拼成一个 32 位字)
#     [4] rm      删掉 .elf/.bin     (它们只是中转产物，留下 .hex 就够了)
#
# 想保留 .elf/.bin（比如要单独 objdump 研究）就在前面加 KEEP=1:
#     KEEP=1 ./tools/build.sh <源文件> <输出.hex>
# ==========================================================================

set -e                      # 任何一步出错就立刻退出，不留下半成品

SRC="$1"                    # 第 1 个参数：源文件
OUT="$2"                    # 第 2 个参数：输出的 hex

if [ -z "$SRC" ] || [ -z "$OUT" ]; then
    echo "用法: ./tools/build.sh <源文件> <输出.hex>"
    echo "例如: ./tools/build.sh asm/sum_1_10.asm program/sum_1_10.hex"
    exit 1
fi

ELF="${OUT%.hex}.elf"       # 字符串处理：把结尾的 .hex 换成 .elf
BIN="${OUT%.hex}.bin"

# gcc 靠文件后缀猜语言：.c 认作 C，.s/.S 认作汇编。
# 你用的是 .asm，gcc 不认识，所以要显式告诉它"这是汇编源文件"。
if [[ "$SRC" == *.c ]]; then
    LANG_OPT=""                    # C 源文件，gcc 自己认得
else
    LANG_OPT="-x assembler"        # 其它后缀一律当成汇编
fi

echo "[1/4] 编译链接   $SRC  ->  $ELF"
riscv64-unknown-elf-gcc $LANG_OPT \
    -march=rv32i -mabi=ilp32 \
    -ffreestanding -nostdlib -nostartfiles \
    -Ttext=0 -e _start -O1 \
    -o "$ELF" "$SRC"

echo "[2/4] 剥掉文件头 $ELF  ->  $BIN"
riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"

echo "[3/4] 转成 hex   $BIN  ->  $OUT"
od -An -tx4 -v "$BIN" | tr -s ' ' '\n' | grep . > "$OUT"

echo
echo "===== $OUT ====="
cat "$OUT"
echo
echo "===== 反汇编（用来逐条核对）====="
riscv64-unknown-elf-objdump -d "$ELF"
# ---- 第 4 步：清理中间文件 ----
# .elf 和 .bin 只是"中转产物"，程序已经写进 .hex 了，删掉让目录保持干净。
# ★ 必须放在 objdump 之后：反汇编要读 .elf，先删就没得看了。
#
# 想留着它们（比如要单独 objdump 研究）就加个环境变量 KEEP=1（见文件开头说明）。
echo
if [ -n "$KEEP" ]; then
    echo "[4/4] 保留中间文件（你设了 KEEP=$KEEP）"
else
    echo "[4/4] 清理中间文件 $ELF $BIN"
    rm -f "$ELF" "$BIN"
fi

echo
echo "完成，$OUT 所在目录现在是:"
ls -l "$(dirname "$OUT")"
