# PCIe 移植与手工 IP 接入说明

## 当前状态

来源：D:/Projects/Maximus-project/fpga/purple-light-fpga-main。
目标：当前 RISCV- 工程，PG2L100H / FBG484 / -6。

按你的要求，IP 的生成、例化、PDS 导入由你操作。此次没有修改 board_top、
rv32I.pds、构建脚本或引脚约束。当前只是完成 PCIe/DMA 源码准备和 DMA TX 单元仿真，
还不是已接入顶层、可以下载的 PCIe 工程。

- rtl/pcie/dma：按来源 PDS 的活动文件清单复制 DMA RTL，不包含 backup 目录。
- rtl/pcie/pcie_test_source.v：128 位固定测试数据源，RGB565 红色 0xF800 重复 8 次。
- rtl/pcie/sources.f：手动添加 RTL 时的文件及 include 路径参考。
- ipcore/pcie_test：你提出手动例化前已复制的原 IP 配置和综合源码，仅供参考；
  未加入当前 PDS，也未新增该 IP 的例化。内部生成文件保持原样。
- docs/pcie_import_manifest.json：导入文件来源和 SHA256，可核对与原工程完全一致。
- sim/pcie/TB_pcie_mwr.v：测试 DMA MWr 发送控制，不包含 PCIe PHY/IP。

## 在 PDS 中核对的原配置

以已复制的 pcie_test.idf 为准。原 IP 版本 1.8，生成器 2022.2-SP6.1。
目标芯片、封装、速度等级均与当前工程一致。

| 项目 | 来源配置 |
|---|---|
| 类型 | PCI Express Endpoint |
| 最高/目标速率 | 5 GT/s（Gen2） |
| 最高链路宽度 | x2 |
| Vendor ID / Device ID | 0x0755 / 0x0755 |
| BAR0 | 64 KiB，32-bit Memory，非预取 |
| BAR2 | 64 KiB，32-bit Memory，非预取 |

其余参数保持原 IDF；不能只凭这个表重新构建全部配置。
当前只迁移 PCIe/DMA 通道，不包含 HDMI、DDR3 帧缓冲或视频算法。

## 推荐接线顺序

1. 你先在 PDS 中导入或生成 PCIe IP，核对模板端口。顶层新增差分参考时钟、
   perst_n、两路 rxp/rxn 和 txp/txn。PCIe 参考时钟与现有 25 MHz sys_clk 不同。
2. 按原例程保留参考时钟域的按键/PERST 复位处理。DMA 工作时钟接 IP 的
   pclk_div2，复位按对应时钟域处理；不要直接使用 CPU 的 25 MHz 时钟。
   原例程复位辅助模块在 IP 的 rtl/hsst_pipe 内，由你随 IP 核对例化。
3. 添加 sources.f 中的 DMA 源文件。ips2l_pcie_dma_ram_init_param.v 是 include
   片段，加入搜索路径，不作为独立 Verilog 模块编译。BAR RAM 包装内部使用
   GTP_DRM18K_E1，PDS 综合和正式仿真需要对应厂商库；本次没有重新生成 RAM IP。
4. 例化 ips2l_pcie_dma，DEVICE_TYPE=0、AXIS_SLAVE_NUM=3，连接下表。
5. 先连接固定测试数据源，使用原 RK 驱动/工具配置合法 DMA 缓冲区并发起小块传输。
   固定数据源不自动启动 DMA，也不分配 RK 内存。成功后再接视频 FIFO。

## IP 与 DMA 对应关系

这里的 master/slave 命名沿用原 IP：master 是 IP 向用户逻辑输出接收到的 TLP。

| PCIe IP 信号 | DMA 信号/用途 |
|---|---|
| pclk_div2 | clk；测试数据/应用逻辑同一时钟域 |
| core_rst_n | 参考原设计的复位处理后接 rst_n |
| cfg_pbus_num / cfg_pbus_dev_num | i_cfg_pbus_num / i_cfg_pbus_dev_num |
| cfg_max_rd_req_size / cfg_max_payload_size | 同名 i_ 前缀输入 |
| axis_master_tvalid/tdata/tkeep/tlast/tuser | i_axis_master_tvld/tdata/tkeep/tlast/tuser |
| axis_master_tready | o_axis_master_trdy |
| axis_slave0/1/2_tready | i_axis_slave0/1/2_trdy |
| axis_slave0/1/2_tvalid/tdata/tlast/tuser | o_axis_slave0/1/2_tvld/tdata/tlast/tuser |

Endpoint 模式不需要原顶层的 RC 配置控制分支。原示例的 UART→APB 调试总线
也不要与 CPU 的 UART 混接。若暂不使用 APB，PCIe IP 和 DMA 的选择、使能、
写使能及地址/数据/选通均接确定的 0，调试输出可留空；不能悬空输入。
原顶层把 DMA 的 i_cfg_ido_req_en、i_cfg_ido_cpl_en、所有 i_xadm_*_cdts 接 0；
移植先保留此配法，正式传输能力由原 DMA/IP 流控行为验证。

| 数据源侧 | DMA 侧 |
|---|---|
| pcie_test_source.data | i_user_data[127:0] |
| pcie_test_source.valid | i_user_data_vld |
| pcie_test_source.sufficient | i_fifo_data_sufficient |
| 固定 0 | i_user_data_last（原发送控制自行计数） |
| o_user_data_rdy | 真实 FIFO 取数/消费控制，固定常量源无需推进 |
| o_dma_tx_busy | 留作状态观测 |

原发送控制会在缺少用户数据时补零，而且最后一个 TLP 会绕过 sufficient 门控。
因此 sufficient 不是完整的欠载保护。接视频前必须保证整个 TLP 的数据连续供应；
不能把 25 MHz 域数据直接跨到 pclk_div2，也不能只接 valid 就认为 FIFO 安全。
此轮保持原 DMA 行为，没有顺带改写其流控和软复位逻辑。

## 约束由你核对后接入

原工程 fdc/pcie_dma_test.fdc 的参考时钟为 100 MHz，参考引脚 F6/E6，
PERST 为 M16、LVCMOS18。这些是原项目记录，不代表此轮重新核对了板卡。
高速收发器有专用位置约束，且层级以 u_ips2l_pcie_wrap 开头；若增加封装层，
必须更新内部层级路径。不要整份照搬含 HDMI/DDR3 的 FDC，也不要把 PCIe 的
pclk/pclk_div2 时钟周期替换成 CPU 的 40 ns。
IIC 的物理引脚/电压约束仍待确认。

## 验证

WSL 在项目根目录执行：

    python3 scripts/check_pcie_dma.py

目前通过：MWr64、256 字节拆成两个 128 字节 TLP、目的地址递增、数据字节序、
下游反压时输出保持、复位。它是纯 RTL 单元测试，不验证链路训练、枚举、
BAR 访问、DMA 完整端到端协议或板级时序。

你完成 IP 例化后，依次做 PDS Compile/综合、约束检查与时序检查，再上板查看
RK lspci 枚举与链路状态，最后用原驱动进行小块 DMA 数据校验。暂不迁移旧 C
驱动到 RV32 裸机程序；RK Linux 驱动与 RV32 固件是不同的软件。
