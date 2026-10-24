# 紫光 Logos2 DDR3 IP 行为模型与 RV32I 接入报告

日期：2026-10-23。参考工程：桌面 `ziguang-fpga2`。交付位置：当前 `rv32I` 工程。

## 1. 交付结论与兼容范围

已编写 `sim/ddr3/ddr3.sv`，模块仍叫 `ddr3`。其 **7 个参数和 85 个端口的声明与参考工程原 IP 相同**，已用脚本逐字符去空白核对。正常读写按 HMIC_S 的 Simplified AXI4 事务规则实现，Linux Icarus Verilog 和 Verilator 的实际执行测试均通过。

**这是一份用户侧读写事务模型，不能宣称与原厂 IP 的全部外部信号、逐拍时序完全等价。** 物理 DDR 引脚、PHY 训练、PLL 动态行为和调试输出没有真实建模；APB 仅提供后文列出的功能近似。参考 IP 的 controller/PHY 内部为加密 `.vp`。原厂 ModelSim 对照在初始化前遭遇厂商 `GTP_PPLL` 除零、NaN 和 SIGFPE，尚未获得原厂事务对照通过的证据。报告和脚本没有把该失败当成通过。

如果后续逻辑遵守握手、允许可变延迟、正确转换地址和字节选通，并使用同一配置的原厂 IP，可以保留同一实例连接切换仿真/硬件源文件。行为仿真通过仍不能代替原厂仿真、约束检查和板上初始化验证。

本次没有修改桌面参考工程，也没有把当前 CPU 的 RAM 或流水线改成 DDR3。

## 2. 实际阅读的材料

| 材料 | 用途 |
|---|---|
| `ipcore/ddr3/ddr3.idf` | IP 版本、FPGA、颗粒组织和时钟配置 |
| `ipcore/ddr3/ddr3.v` | 完整外部接口、地址映射选择、控制器参数、MR 参数 |
| `ipcore/ddr3/ddr3_ddrphy_top.v` | PLL 参数、DFI 时钟周期、初始化加速宏 |
| `ipcore/ddr3/example_design/rtl/test_wr_ctrl_v1_0.v` | 原厂写接口、地址每拍 +8、突发计数 |
| `ipcore/ddr3/example_design/rtl/test_rd_ctrl_v1_0.v` | 原厂读接口、返回拍计数、地址每拍 +8 |
| `hdl/new_ring/frame_ring_ddr3.v` | 实际实例、时钟域、APB/调试信号绑常数 |
| `hdl/new_ring/ddr3_write_ctrl_lite.v` | 写 FIFO、整包预存、预取供数、帧槽推进 |
| `hdl/new_ring/ddr3_read_ctrl.v` | 读 FIFO 空间检查、AR 请求、无反压接收 |
| 官方 `UG042003_Logos2_HMIC_S_IP.pdf`，V1.10，2023-04-28 | 接口规则与边界回卷 |

官方手册位于本机 PDS 安装目录的 `ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/`。重点阅读 PDF 第 31-40 页（端口和时序）、第 54-58 页（寄存器、突发和回卷），并渲染核对第 36-38 页图示。第 36 页图 2-16 实际顺序是 **Bank / Row / Column**；仅提取 PDF 文本会把图中文字顺序混淆，因此以图和 `ADDR_MAPPING_SEL=1` 交叉确认。

参考文件绝对路径、SHA-256 和 `.idf` 参数快照见 `reports/ddr3/source_manifest.json`，便于将来判断原 IP 是否重新生成过。

## 3. 原工程的 DDR3 配置

| 项目 | 实际值 |
|---|---|
| FPGA | Logos2 / PG2L100H / FBG484 / -6 |
| IP | Logos2 HMIC_S，1.10，Controller + PHY |
| 生成器 | PDS 2022.2-SP6.4，build 146967 |
| `.idf` 颗粒选择 | MT41K256M16XX；上板时仍需对照板上实际料号 |
| Row / Column / Bank | 15 / 10 / 3 bit |
| 物理 DQ / DM / DQS | 16 / 2 / 2 bit |
| 用户数据宽度 | 8 × DQ = 128 bit，即每拍 16 字节 |
| 用户写选通 | 16 bit，每位对应一个数据字节，1 表示写入 |
| 原生地址宽度 | 28 bit，以一个 x16 存储位置为单位 |
| 理论地址容量 | 2^28 × 2 字节 = 512 MiB，即 4 Gbit |
| 输入参考时钟 | 25 MHz |
| PPLL 参数 | IDIV=1，FDIV=84，ODIVPHY=2 |
| DFI / core 时钟周期 | 配置值 7619 ps，约 131.25 MHz |
| 用户突发长度 | `len + 1`，1-16 个 128-bit 拍 |
| 颗粒物理突发 | BL8；与用户一次请求的 1-16 拍不是同一个量 |
| 地址排列 | 高位 Bank[2:0]，中间 Row[14:0]，低位 Column[9:0] |

这里“不标准”的主要是 FPGA 用户接口。板外仍是 DDR3 SDRAM 接口；用户通常不用自己发送 ACT、READ、WRITE、PRECHARGE、REFRESH，这些由 controller 和 PHY 完成。

## 4. 实际工程怎样使用 DDR3

数据流为：

```text
HDMI 像素域
  -> hdmi_in_detector（帧标记）
  -> fifo_2_ddr（异步 FIFO，16 bit 转 128 bit）
  -> ddr3_write_ctrl_lite（先备齐整个 16 拍 burst）
  -> ddr3 / 外部颗粒
  -> ddr3_read_ctrl（先确认接收 FIFO 空间）
  -> ddr_2_fifo（core_clk 转 PCIe 读侧时钟域）
  -> PCIe 后续逻辑
```

`frame_ring_ddr3` 里的 IP 实例为 `u_ddr3`，上层实例为 `u_hdmi_fifo`。现有约束依赖这条层级路径，换 IP 或改变层级后需重核约束。原工程把 APB 全部关闭，PHY 调试输入设为默认常数；读写控制器在 IP 输出的 `core_clk` 域运行。

值得保留的设计做法：

- 写侧提前缓存完整突发，并用寄存器提供当前拍；只有看到 `axi_wready` 才推进数据。
- 写侧以 IP 输出的 `axi_wusero_last` 定界，不向 IP 输入自造的 `WLAST`。
- 读侧先为整个突发留空间，再发 AR；每一个 `axi_rvalid` 都必须接收。
- 两个异步 FIFO 负责时钟域转换；IP 本身并没有把 CPU 或像素时钟自动变成用户接口时钟。

需要注意的原工程细节：

1. 写、读控制器均把每个 16 拍突发的地址推进写成 `+256`，并称为字节。对本 IP 来说这是 **256 个原生 x16 位置**，即 512 字节，而该突发只传 256 字节。因此相邻突发间留下 256 字节空隙。两侧算法一致时可以读回，不代表地址单位是字节。
2. `slot << 22` 是原生地址，物理字节基址应再乘 2。因此注释里的“4 MiB 帧槽”实际对应 8 MiB 的物理地址间隔。
3. 原工程上一帧完成位在“下一帧 SOF 已到达”时产生。停止送入下一帧时，最后一帧不一定产生完成位。这是视频帧管理策略，不是 DDR3 的写完成机制。
4. 现有写状态机有预装载周期；若重写控制器，稳妥做法是让第一个写数据在 AW 请求之前就准备好。手册没有保证固定的 AW 到第一次取数间隔。

本次仅记录这些现象，没有修改参考工程。

## 5. 用户接口必须遵守的规则

### 5.1 AW / AR 地址请求

在 `core_clk` 上升沿，`valid && ready` 才表示接受一条命令。等待时必须保持 valid、地址、ID、len、AP 不变；接受后才允许撤销 valid 或发送下一条命令。

`axi_awlen=0` 是 1 拍，`axi_awlen=15` 是 16 拍，AR 同理。ID 是 4 bit；写数据时用 IP 输出的 `axi_wusero_id` 识别所属写请求，读数据用 `axi_rid` 识别所属读请求。示例模型按每个方向的接受顺序服务，不模拟原厂可能的内部重排或调度。

`axi_awuser_ap` / `axi_aruser_ap` 表示自动预充电，与 CPU 地址、字节使能没有关系。模型接受并检查它在等待期间稳定，但不模拟开行、关行的性能差别。

### 5.2 写数据是 IP 主动取数

接口没有 `axi_wvalid` 输入，也没有 `axi_wlast` 输入。

```verilog
// 在 core_clk 上升沿：
if (axi_wready) begin
    // IP 此时已经采样当前 axi_wdata 和 axi_wstrb。
    // 主机可用非阻塞赋值推进到下一份预先准备的数据。
end
```

`axi_wready=0` 时保持当前拍。不能看到 ready 之后才在同一个上升沿“开始准备该拍数据”，因为 IP 会采到原值。

有效写入字节满足 `axi_wstrb[i]=1`，对应 `axi_wdata[8*i +: 8]`；0 保留旧字节。全 0 仍然消耗一个写数据拍。不要把它当成物理 DDR DM 的极性：DM 是高电平屏蔽，WSTRB 是高电平选通。

`axi_wready && axi_wusero_last` 表示该请求的最后一个用户数据拍已被取走。没有 B 通道；它不是可额外观察到的物理落盘确认。模型在这一拍更新内部存储，原厂内部队列、写恢复和同地址读写的顺序保证仍需厂商验证。保守实现应串行化相关读写，不能从独立 AW/AR 接受时间推断同地址的执行先后。

### 5.3 读数据没有反压

接口没有 `axi_rready`。`axi_rvalid=1` 时，这一拍数据、RID 和 RLAST 都有效，接收方必须保存。`axi_rvalid && axi_rlast` 是最后一拍。

要在发出 AR 前，为全部 `len+1` 拍预留存储。不能等读数据到达后再以“CPU 忙”为由暂停 IP。

## 6. 地址换算：RV32I 接入的关键

当前 x16 配置下，一个原生地址单位是 2 字节，一个 128-bit 用户拍覆盖 8 个原生位置。连续拍地址为：

```text
native, native+8, native+16, ...
```

16 拍的连续数据共 256 字节，下一条相邻 burst 的起点通常为 `native + 128`，不能直接加字节数 256。

假设 CPU 使用字节地址，DDR 映射基址为 `DDR_BASE`，则对 16 字节块：

```text
offset       = cpu_byte_address - DDR_BASE
line_byte    = offset & ~0xF
native_addr  = line_byte >> 1
word_lane    = offset[3:2]        // 128-bit 块中的第几个 32-bit 字
byte_lane    = offset[3:0]        // 块中的字节位置
```

32-bit 对齐访问时，简化成：

```verilog
// 这些表达式用于未来的 CPU/DDR 适配器，不是替换现有 memory_core 的代码。
// offset 为已减去 DDR 基址的 29-bit 字节偏移。
wire [27:0] native_addr = {offset[28:4], 3'b000};
wire [6:0] bit_shift = {offset[3:2], 5'b00000};
wire [127:0] wdata128 = {96'b0, cpu_wdata} << bit_shift;
wire [15:0] wstrb16 = {12'b0, cpu_byte_enable} << {offset[3:2], 2'b00};
wire [127:0] shifted_read = axi_rdata >> bit_shift;
wire [31:0] read_word = shifted_read[31:0];
```

这里 `cpu_byte_enable` 已经是该 32-bit 字内的字节选通。SB/SH 的数据和使能必须先按字内偏移移位；符号/零扩展由 CPU 适配层完成。跨 32-bit 字或跨 16 字节块的非对齐访问必须拆分或明确报错，不能仅截断地址。

### 列边界回卷

手册 2.8.2 明确给出：10-bit Column 从 `0x3F8` 开始，第二拍地址变成 `0x000`，不会向 Row 进位。也就是说：

```text
(bank,row,column=0x3F8) -> (bank,row,column=0x000)
```

若希望跨行连续访问，必须拆成两条地址请求，由下一条请求显式给出下一行地址。建议发送前满足：

```text
column_start + (len + 1) * 8 <= 1024
```

模型实现相同的列内回卷，并在回归中检查不会误写下一行。模型要求命令起点低 3 位为 0，遇到非 BL8 对齐地址直接报错；这是本模型支持的合法使用范围，不是对原 IP 低地址位所有行为的等价证明。

## 7. 模型实现与明确限制

| 功能 | 实现 |
|---|---|
| 模块实例接口 | 与原工程相同的 7 个参数、85 个端口 |
| AW、AR | 独立队列，每方向 16 条等待命令，另可有 1 条活动命令 |
| 写取数 | ready 当拍采样，返回对应 ID 和末拍标记 |
| 读返回 | 128-bit，RID、RVALID、RLAST；可插入空拍，没有 RREADY |
| 数据和掩码 | 每字节高电平选通，未选字节保留 |
| 地址 | 全原生地址标签、每拍 +8、列边界不进位 |
| 同地址并发读写 | 模型检测“同一执行周期同一拍”并报错；其他无序请求也不提供硬件顺序保证 |
| 初始化 | 可调等待后置位 init_done；锁定指示为计数近似 |
| resetn | 异步关闭接口、丢弃队列/活动命令，保留已写数据 |
| 内存容量 | 默认最多存 65536 个被写过的 128-bit 块，共 1 MiB 有效数据 |
| 高地址 | 使用标签稀疏保存，可分布在整个 512 MiB 空间，没有取模造成的高低地址别名 |
| 存储表写满 | 明确 fatal；通过编译宏扩大，不会覆盖别的地址 |
| 未初始化读取 | Icarus 默认为 X；可显式选择零；Verilator 为二态语义，不能依赖 X 传播 |
| 自动预充电 | 接受 AP 参数，不建模 bank 开关行和命中率 |
| 刷新/仲裁 | 用可调停顿制造等待，不复现 tREFI/tRFC 或真实调度 |
| 物理 DDR 引脚 | 命令空闲，DQ/DQS 高阻；时钟只是占位，不能连接外部颗粒模型 |
| PHY 调试/校准 | 状态输出为 0；启动动态调试操作会 fatal |

稀疏表限制的是“本次仿真累计写过的不同块数”，不是可访问地址范围。复位不清表。读空地址不分配表项；全 0 strobe 写入也不分配。

模型的复位保留行为不应解释为真实板卡的持久化保证。原厂 PHY 重新训练可能写入校准测试位置；模型没有模拟这些训练写入，也不模拟刷新中断、断电或复位期间的数据有效性。

默认队列深度和服务延迟是仿真选择，不代表厂商 FIFO 深度。不要通过观察本模型的某个固定周期数来设计主机状态机。

### APB 子集

实现地址 `0x00`-`0x05` 的 MR0/MR1/MR2/MR3、控制和状态访问。MR0-2 按手册可写字段更新，MR3 保留，状态只读；CTRL[15:14] 与 CTRL[0] 同时写入触发请求。模型在已有命令排空后切换状态，状态同步返回 APB 域；Self-Refresh、Power Down、MRS 状态下停止接收新 AW/AR，写 Normal 请求恢复。

这只用于软件/控制流程的功能调试：MR 初值按生成参数设置，更新 MR 不会改变真实颗粒时序，不模拟 PHY MRS 命令波形、低功耗退出时间、MRS 自动退出细节或完整 APB 等待时间。APB 未知地址和请求未响应时再次触发会报错。

原参考工程不使用 APB。正式依赖这些功能前必须另做厂商对照。使用 APB 时将 `resetn` 与 `apb_rst_n` 一同复位，避免模拟状态跨域请求残留。

### 时钟模式

默认在 `ref_clk` 首个上升沿后生成周期为 7.619 ns 的 `core_clk`，无需外部提供 UI 时钟。它不会根据参考时钟变化重新计算 PLL，也不会在参考时钟停止时模拟失锁。

定义 `DDR3_MODEL_EXTERNAL_CORE_CLOCK` 时直接令 `core_clk=ref_clk`。此时送入的 `ref_clk` 是仿真 UI 时钟，不再代表硬件 25 MHz 晶振；它适用于无延时的 C++ 驱动或已有统一时钟的系统仿真。该宏只在仿真模型编译中使用。

## 8. Linux 使用方法

在工程根目录执行。只需 Python 3 标准库和对应仿真器；不依赖 Pango 库。

### Icarus Verilog

```bash
python3 scripts/check_ddr3.py
```

等价的单次编译运行：

```bash
mkdir -p build/ddr3/manual
iverilog -g2012 -s tb_ddr3 -o build/ddr3/manual/tb.vvp \
  sim/ddr3/ddr3.sv sim/ddr3/tb_ddr3.sv
vvp build/ddr3/manual/tb.vvp
vvp build/ddr3/manual/tb.vvp +ddr3_random_stalls=1 +ddr3_seed=12345
```

接入你的测试顶层时保留 `sim/ddr3/ddr3.sv`，将 `tb_ddr3.sv` 换成自己的 testbench 和 `.v` RTL。不要同时编译原厂 `ipcore/ddr3/ddr3.v`，否则会出现重复模块。

### Verilator 4.x / 5.x，无延时 C++ 驱动

```bash
python3 scripts/check_ddr3_verilator.py
```

脚本使用 `--cc --exe --build` 和 `DDR3_MODEL_EXTERNAL_CORE_CLOCK`，不需要 `--timing`。C++ 驱动在时钟上升沿前采样当前握手和返回数据，再推进时钟。

较新的 Verilator 也可用 `--binary --timing` 运行带延时的 SystemVerilog testbench；本次实际验证的是 4.038 的 C++ 路径，不能把这一说明当作已经运行过其他版本的证据。

### 可调参数

这些都是运行时 plusargs，不需要在硬件 IP 实例上增加专有参数。

| plusarg | 默认 | 含义 |
|---|---:|---|
| `+ddr3_init_cycles=N` | 32 | 复位释放到初始化的 core 周期计数，N 至少 5 |
| `+ddr3_read_latency=N` | 6 | 读命令出队后的额外等待，N 可为 0 |
| `+ddr3_write_latency=N` | 3 | 写命令出队后的额外等待，N 可为 0 |
| `+ddr3_stall_every=N` | 0 | 周期停顿间隔，0 关闭 |
| `+ddr3_stall_cycles=N` | 1 | 每个停顿周期的阻塞长度，必须小于间隔 |
| `+ddr3_random_stalls=1` | 0 | AW/AR/W/R 分别插入可复现的伪随机停顿 |
| `+ddr3_seed=N` | 1 | 非零随机种子 |
| `+ddr3_zero_init=1` | 0 | 把未写字节读作 0，仅为仿真便利 |
| `+ddr3_core_period_ns=7.619` | 7.619 | 默认时钟生成器周期；外部时钟模式下无效 |

需要更大数据集时，例如 Icarus 编译增加：

```bash
iverilog -g2012 -DDDR3_MODEL_SLOTS=524288 ...
```

这允许累计写入 8 MiB 的不同数据块；标签和仿真器本身还有额外内存开销。运行完整图像帧或大规模 CoreMark 前应据实际写入量调整。

### `.v` 和 `.sv` 可以混用

当前 CPU、板级 RTL 可以继续保存为 `.v`，行为模型保存为 `.sv`。Icarus 用 `-g2012` 编译整个仿真文件集，Verilator 同时传入这些文件即可。SystemVerilog 基本兼容通常的 Verilog RTL，但仍需避开关键字命名等源语言冲突。

单纯把 `.sv` 改后缀为 `.v` 不会把其中的 SystemVerilog 语法变成 Verilog-2001。本次模型使用 `int'(...)` 类型转换、`$isunknown` 等功能，因此保留 `.sv` 更清晰。综合工程不加入这个仿真模型。

## 9. 本次如何仿真与验证结果

Windows PATH 中没有 Icarus 或 Verilator。本次通过已存在的 **WSL Ubuntu-22.04** 运行 Linux 工具，直接访问 `/mnt/c/.../rv32I` 的同一份源文件，没有修改 WSL 原 CPU 工程。

- Icarus Verilog 12.0 原本位于 WSL `/usr/local/bin/iverilog`，运行器为 `/usr/local/bin/vvp`。
- WSL 原本没有 Verilator。使用 `apt-get download verilator` 把 Ubuntu `4.038-1` 安装包下载到当前工程 `build/ddr3/tools`，再用 `dpkg-deb -x` 解包。没有用系统安装命令安装它。
- 编译 Verilator 生成的 C++ 使用 WSL 已有的 g++ 和 make。
- 原厂 IP 对照使用已有 Windows ModelSim SE-64 10.4，位置为 `C:/diskE/modelsim/win64`，以及已有 PDS 仿真库。

解包工具的本机复现方式：

```bash
# 在工程根目录；这些环境变量仅用于本地解包的 Ubuntu 工具。
export VERILATOR_ROOT="$PWD/build/ddr3/tools/extracted/usr/share/verilator"
export VERILATOR_BIN=../../bin/verilator_bin
python3 scripts/check_ddr3_verilator.py \
  --verilator build/ddr3/tools/extracted/usr/bin/verilator
```

系统已正常安装 Verilator 时，无需设置这两个变量，直接执行回归脚本。

| 测试 | 结果 |
|---|---|
| Icarus 默认延迟 | PASS |
| Icarus 每 7 周期停顿 3 周期 | PASS |
| Icarus 随机停顿，种子 12345 | PASS |
| Icarus 读写额外延迟均为 0 | PASS |
| Icarus 读延迟 19、写延迟 11、随机停顿 | PASS |
| Icarus 显式未初始化读零模式 | PASS |
| 非 BL8 对齐地址、AW 等待期间改变地址 | 均按预期拒绝 |
| 4 表项稀疏存储、碰撞探测、表满后读空地址/零选通写 | PASS；继续写新地址按预期拒绝 |
| Verilator 默认、周期停顿、随机停顿、零额外延迟 | 均 PASS；实际总周期数随配置变化 |
| 原 IP 参数/端口声明核对 | PASS，7 参数 / 85 端口 |
| 原厂完整 IP + 颗粒模型对照 | **未通过：厂商 PPLL 在 8940 ns 除零并崩溃** |

核心正向覆盖包括全部 len 取值、全部 ID、全字写、16 个单字节选通、全 0 strobe、原生 +8 寻址、跨列回卷、高地址无别名、40 个排队请求、独立通道读写，以及复位后的存储保留。Icarus 还验证 APB 的 Self-Refresh/Normal 切换和中途复位；C++ 回归不覆盖 APB。

原厂对照脚本为 `scripts/check_ddr3_vendor.py`。它在 build 目录生成文件列表，读取原始加密库；由于导出的 Micron 颗粒模型与 IP 都叫 `ddr3`，仅在 build 副本中把颗粒模块名改成 `ddr3_model`，不修改逻辑。参考 IP 由 SP6.4 生成、本机可用 PDS 是 SP6.1，这是潜在不匹配因素，尚不能确认它就是 PPLL 故障根因。对照脚本的明确失败退出和日志均保留。

所有普通回归日志在 `build/ddr3/iverilog/`、`build/ddr3/verilator/`；原厂对照在 `build/ddr3/vendor/`。精简验证结果见 `reports/ddr3/validation.json`。交付 zip 内不包含厂商加密代码、颗粒模型、下载工具和编译产物。

## 10. 将来接 RV32I 和切回硬件

当前 `rtl/memory.v` / `memory_core.v` 使用一拍同步 RAM 接口，CPU 没有因此自动具备等待几十拍的 DDR 访问能力。**不能只把 `memory_core` 实例换成 `ddr3` 就保持 CPU 正确运行。**

可从最简单的“单笔未完成访问”适配器开始：

1. CPU 发请求时锁存完整地址、宽度、写数据、符号扩展信息，暂停相关流水线阶段。
2. 将字节地址转换为 16 字节块的原生地址；先使用 len=0。
3. 写请求先备齐 128-bit 数据和 16-bit 选通，再发 AW，并等待实际 W 取数末拍。
4. 读请求先保证有一个 128-bit 接收寄存器，再发 AR，保存 RVALID 返回，选择对应 32-bit 字后完成扩展。
5. 等结果有效后只完成一次 CPU 访存，再释放停顿，避免同一 store 在多周期停顿期间重复发出。
6. 若 CPU 仍用 25 MHz、DDR UI 用约 131.25 MHz，使用有握手的跨域请求/响应队列；不要直接跨域连地址和 valid。
7. 正确工作后再加 cache、写缓冲或更长 burst，并在跨列边界前拆包。

DDR 上电不提供程序 `.data`/BSS 初始化保证。软件应从 ROM 等可靠启动源运行，等待 DDR init 完成，再复制 `.data`、清 BSS、设置 DDR 栈。不要因为模型的零初始化选项而省略真实硬件的初始化代码。

切换源文件时：

| Linux 仿真 | PDS 硬件工程 |
|---|---|
| 加入 `sim/ddr3/ddr3.sv` | 加入按目标板重新生成的原厂 `ddr3` 及其全部依赖 |
| 不加入厂商 controller/PHY 库 | 不加入行为模型、testbench、C++ 驱动 |
| 按模型说明生成/驱动 core 时钟 | 使用 IP 真正输出的 core_clk |
| 不连接颗粒级模型 | 正确连接 DDR3 引脚和参考时钟 |
| 做随机延迟、队列与复位回归 | 核对颗粒组织、25 MHz 输入、UI 宽度、时序/管脚约束和校准状态 |

IP 几何或 DQ 宽度改变时，CPU 地址换算、数据选通、容量范围与时钟约束也要一起检查。仅让模块名相同并不足以保证替换正确。

本次已经提供可运行的 Linux 开发替代模型及测试，实际板上可替换性仍需上述适配器、原厂库验证和板卡测试共同确认。
