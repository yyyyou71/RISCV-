# RISC-V FPGA 团队工程：EVOLVE5

面向 RK3568_MES2L100H / PG2L100H-6IFBG484 的自研 RV32IM+Zicsr 处理器与 SoC。
本目录保存我们的 EVOLVE5 完整快照，上传到 RISCV- 的独立分支 kerman-cn-evolve5。
同学原有文件在此分支中保持不变；没有向 main 或 ziguang_rv32i 推送改动。

## 从哪里开始

- [完整工程](project/README.md)：RTL、固件、仿真、测试、PDS 工程和发布位流。
- [实现与 IPC 报告](project/docs/实现验证与IPC报告.md)。
- [上板验收步骤](project/docs/上板验收说明.md)。
- [团队协作说明](docs/团队协作说明.md)。
- [硬件发布清单](project/release.json)：只使用其中引用的位流。

## 当前状态

2026-10-25 同步 EVOLVE5 离线发布快照。五级受限顺序双发射，RV32IM+Zicsr；
I/D Cache 各 1KiB、两路、16 字节行；ROM/RAM 各 32KiB；25MHz、UART115200。
两套发布配置均完成离线功能验证与原约束 PDS 实现，EVOLVE5 尚待实板验收。

| 配置 | BTB/RAS | CoreMark 短仿真 IPC（performance/validation） | LUT / FF / DSP / DRM |
|---|---|---|---|
| balanced | 32 / 0 | 1.145817 / 1.142371 | 9307 / 4991 / 4 / 16 |
| speed | 256 / 8 | 1.157171 / 1.153836 | 10954 / 5995 / 4 / 16 |

上述为每套种子 8 次迭代的 RTL 结果，不足十秒，不是正式实板 CoreMark/MHz。
旧 CACHE3 的实板成绩不代表 EVOLVE5 已经上板。

## 工具与复现

Python3.12、PDS2022.2-SP6.1、Vivado/XSim2025.2、GCC15.2；细节见工程 README。
软件和 license 由各成员自行安装配置，本仓库不包含安装包、许可证或厂商 IP 库。
先在克隆副本运行构建，保留 reports/reference 原始证据；本地绝对路径需按电脑调整。
project 中原始发布文件保持字节不变，可按 FILE_SHA256.txt 校验。

## 协作与同步

本分支用于团队查看和协作。只看代码可以直接浏览或下载；修改代码时请建分支，
通过 Pull Request 合并。同步由手动提交/推送触发，本仓库没有后台自动同步任务。
后续重要版本用独立提交及标签保存，说明离线验证与实板验证状态。

第三方 CoreMark、riscv-tests 保留各自原有许可证；本次没有替自研代码选择新的开源许可证。
