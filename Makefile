# ---------------------- Verilator仿真(不太常用就是) -------------------
CFLAG = -Wall --trace --Wno-MULTITOP
TARGET = VAcore

SRC_V = ./vsrc/GPR_matrix.v ./vsrc/Reg.v ./vsrc/ROM.v
SRC_CPP = TB_test.cpp
WAVE = waveform.vcd

# --------------------- Icarus Verilog：行为级仿真 ----------------------

# -----------Acore模块测试(之后会用来长期跑测试)------------------------
# Acore 回归只编译处理器及其依赖，不包含 SoC 和外设顶层。
ACORE_RTL = $(addprefix vsrc/,Acore.v PC.v ROM.v ROM_core.v decoder.v ALU.v \
            multiply_unit.v multiplier_core.v divide_unit.v divider_core.v memory.v memory_core.v \
            GPR_matrix.v Reg.v hazard_detection_unit.v branch_predictor.v)
IVSRC = ./Iverilog/TB_Acore.v $(ACORE_RTL)
# 同一开关同时控制硬件实例和默认编译 ISA，避免关闭除法器后仍生成除法指令。
ENABLE_DIV ?= 1
ISA ?= $(if $(filter 1,$(ENABLE_DIV)),rv32im,rv32i_zmmul)
ifeq ($(filter $(ENABLE_DIV),0 1),)
$(error ENABLE_DIV 只能设为 0 或 1)
endif
ifeq ($(ENABLE_DIV):$(ISA),0:rv32im)
$(error 关闭除法器时请使用 ISA=rv32i_zmmul 或 ISA=rv32i)
endif
PROG     ?= sum_1_10_c
PROGFILE  = program/$(PROG).hex
# 默认按程序名选择 C 源文件，也可用 C_SRCS="文件1.c 文件2.c" 覆盖。
ifeq ($(PROG),sum_1_10_c)
C_SRCS ?= csrc/software/main.c
else
C_SRCS ?= csrc/software/$(PROG).c
endif
IVDIR = ./obj_iv
IVOUT = $(IVDIR)/TB_Acore_$(PROG)_div$(ENABLE_DIV).out
IVVCD = TB_Acore.vcd
IVFLAG = -Wall -g2012 -DPROG_FILE='"$(PROGFILE)"' \
			-DDATA_FILE='"program/$(PROG).data"'


# -----------decoder模块测试------------------------
# IVSRC = ./Iverilog/TB_decoder.v ./vsrc/decoder.v
# IVDIR = ./obj_iv
# IVOUT = $(IVDIR)/TB_decoder.out
# IVVCD = TB_decoder.vcd
# IVFLAG = -Wall -g2005

# # -----------memory模块测试-----------------------
# IVSRC = ./Iverilog/TB_mem.v ./vsrc/memory.v
# IVDIR = ./obj_iv
# IVOUT = $(IVDIR)/TB_mem.out
# IVVCD = TB_mem.vcd
# IVFLAG = -Wall -g2005

# # -----------内存模块测试------------------------
# IVSRC = ./Iverilog/TB_testMem.v $(wildcard vsrc/*.v) # 源文件只用指定TB即可，其他的在命令中用-y vsrc 指定iverilog去目录中自己找对应模块,
# 												   # 也可以向这里用wildcard函数来解释通配符*
# IVDIR = ./obj_iv
# IVOUT = $(IVDIR)/TB_testMem.out
# IVVCD = TB_testMem.vcd
# IVFLAG = -Wall -g2012





# ==========================================================
# verilator部分
# ==========================================================

# 进行整体构建
.PHONY:verilator
verilator:./obj_dir/time
	verilator $(CFLAG) --cc $(SRC_V) --exe $(SRC_CPP)
	touch ./obj_dir/time
./obj_dir/time:$(SRC_V) $(SRC_V)
	verilator $(CFLAG) --cc $(SRC_V) --exe $(SRC_CPP)
	touch ./obj_dir/time

# 把电路转化为cpp类
.PHONY:CLASS
CLASS:$(SRC_V)
	verilator --cc $(SRC_V)


# 编译
./obj_dir/$(TARGET):./obj_dir/time
	$(MAKE) -C obj_dir -f $(TARGET).mk $(TARGET)

# 执行
.PHONY:run
run:./obj_dir/$(TARGET)
	./obj_dir/$(TARGET)

# 查看波形
.PHONY:wave
wave:$(WAVE)
	gtkwave $(WAVE)

# 清理编译内容（verilator + iverilog 产物）
.PHONY:clean
clean:
	rm -rf obj_dir
	rm -rf *.vcd
	rm -rf $(IVDIR)
	rm -f $(IVVCD)
	rm -rf program
	rm -rf build

# help
.PHONY:help
help:
	@echo 'ENABLE_DIV=1    enable hardware divide (default RV32IM); 0 selects Zmmul'
	@echo 'test-divide     check divider arithmetic, pipeline integration and hardware switch'
	@echo 'coremark-verilator  run CoreMark on Verilator (100 iterations per seed set by default)'
	@echo 'coremark        build, simulate and check both CoreMark seed sets (ITERATIONS=1 by default)'
	@echo 'coremark-build  build CoreMark images only; sources: csrc/coremark_port/sources.mk'
	@echo '                options: ITERATIONS=10 COREMARK_MODE=performance MAX_CYCLES=20000000'
	@echo 'build           compile C via build.sh: make build PROG=hello_coremark'
	@echo '                optional: C_SRCS="file1.c file2.c"; asm/start.s is included automatically'
	@echo "CLASS  		verilator the circuit to cpp class"
	@echo "verilator  	verilator the whole TestBench"
	@echo "run		run the simulation"
	@echo "wave		check the waveform"
	@echo "clean		remove all the build file"
	@echo "iv		build and run the iverilog testbench,using parameter < PROG= >  can choose .hex file"
	@echo "iv-build	compile the testbench only"
	@echo "iv-lint		check sources only (verilator --lint-only)"
	@echo "iv-wave		check the waveform (TB*.vcd)"
	@echo "iv-clean	remove iverilog build output"




# ==========================================================
# Iverilog部分：行为级仿真 + decoder 自检测试台
# ==========================================================

# 编译裸机程序，生成 program/$(PROG).hex 和 program/$(PROG).data。
# 启动代码放在最前面，保证当前链接脚本下 _start 位于 ROM 起始地址。
.PHONY:build
build: build.sh link.ld asm/start.s $(C_SRCS)
	mkdir -p program
	ISA="$(ISA)" bash build.sh "$(PROGFILE)" "program/$(PROG).data" asm/start.s $(C_SRCS)

# 仿真：先编译，再运行
.PHONY:iv
iv:$(IVOUT)
	vvp $(IVOUT)

$(IVOUT):$(IVSRC) $(PROGFILE)
	mkdir -p $(IVDIR)
	iverilog $(IVFLAG) -s TB_Acore -PTB_Acore.ENABLE_DIV=$(ENABLE_DIV) -o $(IVOUT) $(IVSRC)

# 只编译不运行
.PHONY:iv-build
iv-build:$(IVOUT)

# 只做静态检查，比跑仿真快（复用 verilator，-y 指定模块搜索目录）
.PHONY:iv-lint
iv-lint:$(IVSRC)
	verilator --lint-only -y vsrc $(IVSRC)

# 查看 decoder 波形
.PHONY:iv-wave
iv-wave:$(IVVCD)
	gtkwave $(IVVCD)

# 清理 Icarus Verilog 产物
.PHONY:iv-clean
iv-clean:
	rm -rf $(IVDIR)
	rm -f $(IVVCD)

# CoreMark 独立构建，保留上面普通 C 程序的 build/iv 用法。
include csrc/coremark_port/sources.mk
ITERATIONS ?= 1
COREMARK_MODE ?= both
MAX_CYCLES ?= 20000000
SIMULATOR ?= iverilog
COREMARK_ARGS = --iterations $(ITERATIONS) --mode $(COREMARK_MODE) --max-cycles $(MAX_CYCLES) --simulator $(SIMULATOR) --isa $(ISA) --enable-div $(ENABLE_DIV)

.PHONY: coremark coremark-build
coremark:
	python3 scripts/coremark.py run $(COREMARK_ARGS) --sources $(COREMARK_SRCS)

coremark-build:
	python3 scripts/coremark.py build $(COREMARK_ARGS) --sources $(COREMARK_SRCS)

.PHONY: coremark-verilator
coremark-verilator: SIMULATOR = verilator
coremark-verilator: ITERATIONS = 100
coremark-verilator: MAX_CYCLES = 200000000
coremark-verilator: coremark

# 乘法 IP 接口、算术边界及 Acore 流水线回归，产物保存在 build/multiply。
.PHONY: test-multiply
test-multiply:
	python3 scripts/test_multiply.py

.PHONY: test-divide
test-divide:
	python3 scripts/test_divide.py

