# RV32 与 RK 的 IIC 数据通道

## 此轮完成

CPU -> MMIO -> 64 字节 FIFO -> 原单字节 IIC 邮箱 -> RK。
RK -> 参数暂存/提交 -> CPU 参数寄存器 -> 固件处理。
顶层 IIC_BOOT_TEST 默认值改为 0，不再自动插入 0xA5。
保留参数设为 1 的旧测试模式（会在 CPU 数据之前插入一个 A5）。
没有新增/重新生成厂商 IP，没有修改 PDS 工程、引脚或时序约束。

当前所有应用接口均为 25 MHz sys_clk，同步 FIFO 不做跨时钟域。
FIFO 64 字节，另有原 IIC 邮箱 1 字节；总缓存最多 65 字节。
旧 RK 程序 status/recv/set 可继续使用。寄存器 0x20 仍是邮箱计数 0/1，
不代表整个 FIFO 深度。每次 recv 取走并确认一个字节，下一字节自动补入邮箱。

## 软核寄存器（均使用对齐 32 位访问）

| 地址 | 访问 | 含义 |
|---|---|---|
| 0x00030200 | W | 将最低 8 位加入发送 FIFO |
| 0x00030204 | R | bit0 可写；bit1 写满丢弃粘滞标志；bit2 新参数待处理；bit3 参数覆盖粘滞标志；bits14:8 FIFO 字节数，不含邮箱 |
| 0x00030208 | R | 最近一次已提交的 32 位参数 |
| 0x0003020C | R | CPU 侧 32 位参数版本号，每次提交加 1 |
| 0x00030210 | W | 写入已处理版本号；仅匹配当前版本时清除待处理位 |
| 0x00030214 | W | bit1 写 1 清发送溢出，bit3 写 1 清参数覆盖 |

FIFO 满时硬件不会阻塞 CPU 总线：本次写入被拒绝并置溢出标志。
软件先调用 rk_try_send，它返回 0 时保留数据、稍后重试。
即便满状态同一周期有出队，本周期写仍拒绝；下一周期可重试。
只支持单 CPU 生产者，若中断和主循环均发送，需要软件串行化。
参数采用最新值语义；CPU 未确认时再次提交会置覆盖标志，不是命令队列。
同周期的新参数优先于旧版本确认，避免误清除新的待处理通知。

firmware/rk_link.h 提供 rk_try_send、rk_get_parameter、rk_ack_parameter。
读取参数通过版本号前后比对获取一致快照；处理后确认该版本。
版本号在复位清零，32 位自然回绕；IIC 的 0x15 仍为原 8 位提交计数。

## 固件与部署（重要）

firmware/iic_service.c 为持续运行的应用示例，通信驱动可直接用于后续业务。
启动串口打印 RV32 IIC SERVICE；向 RK 队列放入 RV32 READY 加换行（11 字节）。
之后接收参数，把低两位写到 GPIO，并将参数按低字节在前回传 4 字节。
这是可验证的业务接入示例，不代表已经实现你的最终数据生成算法。

已编译固件存放在 firmware/iic_service/：rom.hex、ram.hex、ram_bytes.hex。
合并远程后，firmware 根目录保留远程 CoreMark 镜像；IIC 服务镜像仍单独存放。
自检/IIC 回归由脚本临时编译各自镜像，不覆盖远程 CoreMark 镜像。
仅修改 RTL 后下载旧自检固件，不会发送 READY，也不会处理参数。

在 WSL 项目根目录重新构建服务固件：

    python3 scripts/build_firmware.py --app iic_service --image-dir firmware/iic_service

请你在 PDS 中操作已有的存储器 IP：

1. pango_rom 初始化文件选择本项目 firmware/iic_service/rom.hex。
2. pango_ram 初始化文件选择本项目 firmware/iic_service/ram.hex（32 位字）。
3. 保持原深度、位宽、读延迟等配置，重新生成两个 IP。
4. 再重新编译、综合、布局布线、检查时序并生成下载文件。

不要把 ram_bytes.hex 当作 32 位 RAM IP 初始化文件，它是行为仿真模型使用的。
旧生成的 IP 中有旧机器路径和已嵌入的初始化常量，因此只替换 hex 文件并不够。
不要运行现有 build_fpga.ps1 来部署服务版：它是上游 CoreMark 构建流程，会生成其他固件并自动操作 IP。
本次未运行 IP 生成、PDS 实现或下载。

## 上板检查（RK 端仍用原程序）

下载新固件后按复位，UART 应打印 RV32 IIC SERVICE。
在 RK 的 rk_iic 目录：

    ./rk_iic_demo /dev/i2c-0 status
    for n in $(seq 1 11); do ./rk_iic_demo /dev/i2c-0 recv; done
    ./rk_iic_demo /dev/i2c-0 recv

11 个字节应为 52 56 33 32 20 52 45 41 44 59 0a；再一次应为空。

    ./rk_iic_demo /dev/i2c-0 set 0x12345679
    for n in 1 2 3 4; do ./rk_iic_demo /dev/i2c-0 recv; done

应依次收到 79 56 34 12；逻辑 GPIO[1:0]=01（灯亮灭取决于板上极性）。
这证明字节经过了真实软核处理，而不是顶层固定数据源。
RK 仍需主动轮询读取，FPGA 从机不会主动发起 IIC 事务。

## 验证与边界

    python3 scripts/check_sim.py --test TB_rk_cpu_bus
    python3 scripts/check_sim.py --test TB_cpu_iic

前者覆盖队列满/空、顺序、指针回绕、并发出入队、错误访问宽度/地址、溢出清除、
参数更新与确认竞争、复位。后者运行实际 RV32 固件，通过串行 IIC 事务验证
启动文本、参数提交到 CPU、GPIO 更新、回传、未读数据期间的复位恢复。

协议保持版本 1：peek 不消费，consume 释放邮箱；必须只有一个 RK 消费者。
consume 不是幂等操作，错误后盲目重试可能丢弃下一字节；使用原库的不自动重试策略。
应用确认仍指 CPU 已获取/使用参数；RK 的 set 成功只确认寄存器提交。
持续高吞吐、消息帧、序号/CRC、异常后的重连协商仍需按最终业务补充并实测。
本轮是应用通道实现及验证，不是对所有现场故障的量产认证。
