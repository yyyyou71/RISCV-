# ---------------------- Verilator仿真(不太常用就是) -------------------
CFLAG = -Wall --trace --Wno-MULTITOP
TARGET = VAcore

SRC_V = ./vsrc/GPR_matrix.v ./vsrc/Reg.v ./vsrc/ROM.v
SRC_CPP = TB_test.cpp
WAVE = waveform.vcd

# --------------------- Icarus Verilog：行为级仿真 ----------------------

# -----------Acore模块测试(之后会用来长期跑测试)------------------------
IVSRC = ./Iverilog/TB_Acore.v $(wildcard vsrc/*.v) # 源文件只用指定TB即可，其他的在命令中用-y vsrc 指定iverilog去目录中自己找对应模块,
												   # 也可以向这里用wildcard函数来解释通配符*
PROG     ?= sum_1_10_c
PROGFILE  = program/$(PROG).hex
IVDIR = ./obj_iv
IVOUT = $(IVDIR)/TB_Acore_$(PROG).out      # ★ 加 _$(PROG)
IVVCD = TB_Acore.vcd
IVFLAG = -Wall -g2012 -DPROG_FILE='"$(PROGFILE)"'


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

# help
.PHONY:help
help:
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

# 仿真：先编译，再运行
.PHONY:iv
iv:$(IVOUT)
	vvp $(IVOUT)

$(IVOUT):$(IVSRC) $(PROGFILE)
	mkdir -p $(IVDIR)
	iverilog $(IVFLAG) -o $(IVOUT) $(IVSRC)

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

