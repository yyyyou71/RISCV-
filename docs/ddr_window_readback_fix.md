# DDR 窗口读回旧 A7：修复与验证

## 已复现的问题

`rtl/ddr_cpu_window.v` 的 `cpu_buf[0:63]` 原来在一个时序过程中同时接受动态 CPU 单字写入，以及读完成时的过程循环批量回装。PDS 2022.2-SP6.1 把它实现成 RAM/寄存器副本，但没有等价保留 DDR 读完成时的回装行为。

修改前的独立实验先将 CPU 窗口填为 `A7A7A7A7`，再让独立 DDR 响应器返回 `314D4941`：RTL 读到 `314D4941`，综合网表仍读到 `A7A7A7A7`。原始证据在 `build/reference-comparison-20261103/window-gate-io/`。

该故障不是把异步读变成了同步读：整板使用的 `GTP_RAM64X1SP` 本身就是同步写、异步读。错误是综合前后写回装载行为不一致。普通 `reg` 数组不强制使用触发器；发现 RAM 映射本身也不能单独证明功能错误。

## 源码修改

原来的两个写入入口：

```verilog
for (cpu_i = 0; cpu_i < 64; cpu_i = cpu_i + 1)
    if (cpu_i < (length_reg >> 2))
        cpu_buf[cpu_i] <= core_buf[cpu_i / 4][(cpu_i % 4)*32 +: 32];

if (window_wr)
    cpu_buf[dev_addr_wr[7:2]] <= dev_wdata;
```

现在每个字只有一个静态索引写入过程：

```verilog
generate for (cpu_word=0; cpu_word<64; cpu_word=cpu_word+1) begin : g_cpu_buffer
    always @(posedge clk) begin
        if (cpu_reset_n) begin
            if (cpu_window_write && dev_addr_wr[7:2] == cpu_word)
                cpu_buf[cpu_word] <= dev_wdata;
            else if (readback_commit && cpu_word < (length_reg >> 2))
                cpu_buf[cpu_word] <= core_buf[cpu_word/4][(cpu_word%4)*32 +: 32];
        end
    end
end endgenerate
```

同步器、请求/应答翻转、BUSY/DONE、MMIO 地址、AI/视频任务隔离和组合读接口不变。数据本身不增加整阵列复位，由 `valid_words` 保护。读完成一次更新有效位掩码，并用 OR 保留本次短读范围外原本有效的字，保持旧接口行为。

## 回归

Windows 使用本机已有 PDS/ModelSim 和许可环境，指定一个不存在的新输出目录：

```powershell
python scripts/check_ddr_window_gate.py --gate-only --out build/ddr-window-gate-new
```

默认可在 RTL 与 PDS 功能网表执行同一测试；`--gate-only` 仅执行综合网表检查，按本轮用户要求后续不再重复 RTL 仿真。18 个场景覆盖所有 16～256 字节长度、跨列拆分、高地址、DDR 响应停顿；每次先把全部 CPU 窗口写成 A7，再由独立响应器提供随地址变化的数据，并逐字检查。短读同时检查范围外字保持。

本次 `build/ddr-window-fix/gate/result.json`：RTL 和综合网表均通过，18 场景、19 个原生读取；CPU 缓冲映射为 2048 个有效使能触发器，无影子 RAM。

另外执行了单双发射 CPU 的真实 runtime/model-commit 定向测试，后部 A7 写入与窗口复用后模型/后处理头仍正确。五类算子各两个小输入与 C 黄金对比、非法参数、随机等待/故障回归通过；地址流水线 256 个全位宽输入、快照、反压和取消检查通过。

## 时序处理

修改前定向查询显示，搬运模块到 DDR IP 的最差 setup 为 +2.044 ns，数据选择索引到 DDR 写数据寄存器为 +2.056 ns。因此本次不移植参考工程的 WDATA 预取修复。

针对实际最差 AI 地址路径，保留 `ai_address_math` 的 `a_reg/b_reg` 请求快照寄存器，避免 ADS 将该级吸入远处的 DSP 输入，把引擎操作数选择放在到 APM 的长路径上。算术、握手和流水线有效位不变。

画框配置写入改为 16 组静态寄存器银行，避免动态部分选择产生的极短逐位反馈路径。现有展示控制用例已增加全部 16 框传递及 BUSY 时写入保护检查。

完整综合、布局布线和最终 STA 的本轮状态与结果保存在 `build/ddr-window-fix/board-run1/`，最终资源/时序以本轮根目录 `place_route/acore_dual_top.prr`、`report_timing/acore_dual_top.rtr` 为准。生成位流不等于时序通过；在最终报告出来前不把上述 RTL 修改称为时序收敛。

## 验证边界

模块回归使用独立原生 DDR 响应器和真实厂商逻辑原语，不包含 PHY、颗粒、SDF 或真实板卡。CPU/算子回归使用行为 DDR。实板需下载本次对应新位流并重新上传模型；旧位流不包含该修复。没有更改量化规则、模型校验、DDR IP 参数或时钟周期来回避故障。
