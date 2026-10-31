# 主工程 FSPI 与成功测试版本的差异检查

> Update 2026-10-31: FSP2 source integration completed. See fspi_main_50m.md; this document records the pre-change audit.

日期：2026-10-30。用户反馈重新下载测试位流后通信成功；未指定通过的是原厂工具还是SMDT_V3、测试长度或次数，因此不扩大板级验证范围。
本次仅检查和记录，不修改主工程RTL、软核、固件、IP、约束或RK程序。

## 结论

主工程没有同步为上板成功的50MHz版本，不能直接使用当前主工程位流进行同样的FSPI测试。

| 检查项 | 主工程 | 独立50MHz测试工程 |
|---|---|---|
| 收发实现 | rtl/rk_fspi/rk_fspi_adapter.v，25MHz系统时钟过采样，设计用于<=1MHz SCK | projects/fspi_test_50m/fspi_sck_slave.v，直接使用SCK上升/下降沿 |
| CPU接口 | 有索引/数据/状态/清除MMIO，CPU与SPI在同一系统时钟域 | 没有CPU接口，只有SPI访问2KB缓冲区 |
| 物理顶层 | rv32I.pds选择acore_dual_top，没有SPI端口；board_top也未向下传递ENABLE_FSPI | fspi_loopback_top接出SCK/CS/DQ0..3 |
| 约束 | 主board/pins.fdc和timing.fdc没有FSPI端口/时钟约束 | 独立pins.fdc和20ns SPI时钟及IO延迟预算 |
| RK工具 | csrc/rk_fspi仍请求1MHz、mode0、双向quad标志和命令/数据两段 | 测试目录rk_tool为SMDT_V3：50MHz、mode3、按方向配置、单段payload |

## 正式集成需要完成

1. 把已验证的SCK域收发部分提取为可复用模块，保留协议和边沿时序。
2. 增加SCK域与CPU系统时钟域之间的缓冲区、所有权与状态跨域方案。
   原测试模块的mem没有CPU端口，不能直接给同一个寄存器数组增加第二时钟写入。
   需要合法的双时钟存储或独立收发缓冲，并为停止SCK时的交接/复位设计握手。
   如需要厂商存储IP，配置和生成仍交由用户处理。
3. 通过acore_dual_top -> board_top -> soc -> peripheral_bus连接并启用FSPI。
4. 将FSPI六个引脚及50MHz时序预算纳入主工程，在视频/DDR/PCIe同时存在时重新做实现与时序检查。
5. 将csrc/rk_fspi同步到原厂调用方式，并验证方向切换和2KB边界。
6. 明确最终CPU MMIO地址后再更新对应驱动和应用；不擅自改动现有软核固件。
7. 回归CPU->RK、RK->CPU、访问互斥/忙状态、帧中断、复位、IIC及视频/DDR功能。

## 地址核对与之前说明的纠正

总线现有条件是ENABLE_VIDEO ? 0x30700 : 0x30300，不是“工程中有视频就自动改地址”。
当前acore_dual_top使用独立acore_video_platform，并通过board_top开启ENABLE_FRAME_CONTROL；
未向soc传入ENABLE_VIDEO=1，所以该参数保持默认0。
如果仅补上FSPI使能、其他参数不变，现有译码会选0x30300。
固件fspi_link.h仍固定0x30300；只有最终配置选择0x30700才必须跟着改该地址。
旧fspi_service预编译镜像还存在IIC旧地址兼容性问题，不能作为新系统联调结果。

## 引脚检查

参考SCK L19、CS L20、D0 N22、D1 M22、D2 M18、D3 L18。
当前主board/pins.fdc未发现这六个管脚已分配给其他顶层信号。
这只是文件级冲突检查，不等于主工程启用FSPI后的bank/布局布线检查通过。

## 验证边界

独立回环上板成功不等于CPU到RK数据通路已通过。
原主工程1MHz模块测试通过也不能证明能工作于50MHz。
保留成功测试目录作为基线，正式集成应另做完整验证，不能把低速主模块直接调高频率。
