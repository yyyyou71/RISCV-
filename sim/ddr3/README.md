# DDR3 仿真入口

`ddr3.sv` 是桌面参考工程 Pango Logos2 HMIC_S 1.10 的用户侧事务替代模型，模块名为 `ddr3`，参数和端口声明保持一致。

在工程根目录：

```bash
python3 scripts/check_ddr3.py
python3 scripts/check_ddr3_verilator.py
```

现有 `.v` RTL 可以与此 `.sv` 文件混合编译。Icarus 需要 `-g2012`；Verilator 的 C++ 路径需要定义 `DDR3_MODEL_EXTERNAL_CORE_CLOCK`（脚本已设置）。

硬件综合时加入原厂 IP，仿真时加入这里的模型，避免同名模块重复编译。完整规则、地址换算、参数、验证结果和等价范围见 [使用报告](../../docs/ddr3_usage_report.md)。

注意：不是 PHY/引脚级模型，也没有完成原厂逐拍等价验证。原厂对照在 PPLL 初始化中崩溃，详情见报告。
