# 模型上传故障的补充验证

所有用例的通过范围分别记录，不将局部结果合并成全链路通过。
本轮不修改功能 RTL、板上固件或模型校验条件。

| 检查 | 执行内容 | 结果文件 |
| --- | --- | --- |
| 官方 DDR 定向验证 | 实际块搬运模块、厂商控制器/PHY、颗粒模型；41 次读写、旧数据保持、16 字节使能 | `reports/spi_image/vendor_ddr.json` |
| 连续完整上传 | 真实双发射 CPU 和现有固件、SPI 引脚波形、实际 DDR 窗口和共享仲裁；全部 13,372,720 字节连续上传，每块检查 native 写地址、数据、字节使能，提交后再检查整个 DDR 内容 | `reports/spi_image/continuous_upload_full.json` |
| 随机阻塞上传 | 同一 CPU/SPI 通路，DDR 随机停顿，前 512 块；仅为局部测试 | `reports/spi_image/continuous_upload_partial-512.json` |
| CPU 与官方 DDR 组合 | 实际 CPU、固件、SPI、窗口跨时钟、共享仲裁、官方控制器/PHY和颗粒；最终 144 字节 CHUNK 和 COMMIT | `reports/spi_image/vendor_cpu_spi_commit.json` |
| 时钟比例与响应延迟 | 四状态 Icarus，单发射/双发射各 4 种配置；真实运行时读写和模型头校验 | `reports/spi_image/commit_clock_stress.json` |
| RK/软核软件检查 | 主机客户端协议、完整模型加载、上传后元数据破坏、输入绑定 | `reports/preprocess/network_software.json` |
| 现有实现时序复核 | 读取现有布局布线时序报告，不重新综合，不宣称时序违例就是故障原因 | `reports/spi_image/upload_timing_review.json` |

## 两项长仿真的区别

连续完整上传使用 Verilator 和行为 DDR，**不预置模型头、不跳过前缀、
不改写固件的 received/hash 状态**。SPI 波形由测试平台产生，不代表已验证
RK Linux 的 spidev、实际线路信号完整性或 FPGA 物理时序。
完整数据需要更大的有标签存储表（1,048,576 个 128 位槽）；表满明确报错，
不允许以截断地址的方式循环覆盖。`--chunks` 模式即使通过也不证明整包通过。

官方 DDR 组合用例在 CPU 启动前通过真实 native 写操作放入两处模型头及两处
后续写数据，再启动原固件；前缀接收计数/FNV 使用测试平台快进，最终块和
COMMIT 通过真实 SPI/CPU 路径执行。因此它验证真实接口组合，**不是官方 PHY
级整包上传，更不是整网推理**。CPU ROM/RAM、乘法器仍使用周期行为模型。

组合仿真每 100 us 保存一次 `build/spi-vendor-commit/latest.ckp`，运行上限
3 小时；达到上限可从同一编译版本的断点恢复。ModelSim 10.4 对两处前向
net 引用不兼容，仅在 `build/spi-vendor-commit/compat/` 的副本中移动声明，
不改表达式或逻辑；原工程源码保持原样。该工作库与官方 DDR 定向验证隔离，
不会破坏之前的断点。

## 运行入口

WSL 中运行：

```sh
python3 scripts/check_spi_model_full.py
python3 scripts/check_spi_model_full.py --skip-build --chunks 512 --random-stalls
python3 scripts/check_commit_clock_stress.py
python3 scripts/check_board_network.py
```

Windows Python 中运行 `scripts/check_spi_vendor_commit.py`。它使用已通过的
官方 DDR 定向仿真工作库副本；需要保留 `build/vendor-ddr/work` 和原厂库。

尚未做布局布线后 SDF 仿真、硬件亚稳态模拟、RK 实机线路测试。现有时序
报告仍有违例；纯 RTL 通过不能清除这些风险。各 JSON 中 `state=running`
或 `passed=false` 均不得当作通过。
