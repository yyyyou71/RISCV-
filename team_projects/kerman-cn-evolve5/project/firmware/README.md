# CACHE3 上板与验证软件

当前阶段以根目录 README.md 和 docs/硬件配置与计数器.md 为准。

本版保留 MACHINE1/BP1 软件接口，构建标识为 CACHE3_BOARD。mimpid 显示 CPU 预测配置；新增 platform.c 直接读取硬件 HW_ID/HW_CFG、缓存几何与时钟配置。三种 CoreMark 使用相同二进制，分别配对 burst、word、uncached 位流。每个结果后打印一次累计硬件计数快照；它不表示算法计时区间内的命中率。

`machine/cache_probe.S` 是自检汇编，用三个同组地址核对 LRU、命中/缺失和局部写入，并通过逐出后重读验证直写。`platform_cache_selftest` 再检查 MMIO 和突发活动；通过后继续异常与中断演示。

- `machine/machine.h`：陷阱帧定义和 CSR 辅助宏。
- `machine/trap_entry.S`：144 字节、16 字节对齐的现场，保存并恢复 x1—x31 及四个异常 CSR，最后执行 MRET。
- `machine/machine.c`：初始化 mtvec、关闭中断，分发异常和定时器中断。默认未处理异常打印 MACHINE_FATAL 并进入软件循环。
- `machine/probes.S`：异常演示用的故意错误指令，不加入 CoreMark 固件。
- `apps/machine_demo.c`：11 类异常、两层嵌套陷阱和每 250 ms 的定时器中断。
- `coremark_port/`：CoreMark 移植层；测量时全局中断和 MTIE 关闭。
- `runtime.c`：保留 OPT1 通用软件乘法及必要除法/内存函数，没有引入乘除法 M 扩展。
- `drivers.c` / `include/soc.h`：既有 UART、GPIO、64 位 MMIO 计时器驱动。

启动先设置 sp/gp、复制 .data、清零 .bss。专用构建脚本再插入 machine_init，之后调用应用。基础 crt0.S 自身仍是历史模板，不代表普通 ECALL 在新核心中会停机；软件必须安装异常入口并决定如何退出。

使用 `build_machine_demo.py` 构建演示，使用 `build_coremark.py` 构建 CoreMark。两者以 rv32i_zicsr2p0 / ilp32 编译，同一固件各源文件采用相同优化选项。构建不链接预编译 libgcc/newlib。ELF 检查允许机器态指令；演示中的唯一 0xffffffff 指令按 probe_illegal_fault 符号地址精确登记，其他未知机器码仍导致失败。

链接布局保持 32 KiB ROM、32 KiB RAM和顶部 4 KiB 栈。没有堆、操作系统、独立中断栈或任意深度嵌套保证。计时器比较是电平中断，ISR 通过更新比较值或关闭比较来消除待处理状态，写 mip 不会清 MTIP。

自定义处理函数可以覆盖弱符号 machine_exception / machine_timer_interrupt。恢复地址通过 frame->mepc 指定；恢复时保持 MIE 关闭直到 MRET。为避免递归故障，处理函数应使用有效栈并保持有界执行。
