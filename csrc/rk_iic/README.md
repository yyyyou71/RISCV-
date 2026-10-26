# RK 端 I2C 调用模块

这里是运行在 RK Linux 用户态的 C 模块，不是运行在 RV32 软核中的裸机程序。
对应 vsrc/rk_iic 的版本 1 寄存器协议，默认 7 位从机地址为 0x66。

## 文件

- rk_iic.h / rk_iic.c：可复用的寄存器访问、参数提交、邮箱读取接口。
- rk_iic_demo.c：status、set、recv 三个命令的示例。
- test_rk_iic.c：模拟 Linux ioctl 的主机测试，不需要连接板卡。

## 编译

在本目录执行 make，使用当前机器的 Linux C 编译器。
make test 运行软件模拟测试；WSL 编译出的程序通常用于本地验证，不能直接作为 RK 可执行文件。

RK 板上如有 GCC，可在板上 make。交叉编译时使用与 RK 系统 ABI/libc 匹配的工具链：
make CC=/path/to/target-toolchain-gcc
不要使用 riscv64-unknown-elf-gcc。Android 系统应使用适配系统的 NDK/厂商工具链。
切换工具链前先 make clean，避免误用旧的本机程序。

## 运行示例（在 RK 上）

    ./rk_iic_demo /dev/i2c-0 status
    ./rk_iic_demo /dev/i2c-0 set 0x12345678
    ./rk_iic_demo /dev/i2c-0 recv

总线编号需现场确认。要求 i2c-dev、正确 pinmux、总线速度及设备访问权限。
FPGA 的适配模块也必须已经接到物理引脚并下载；当前独立框架尚不满足上板条件。
程序不修改设备树、不设置 SCL 频率、不加载驱动，也不使用强制占用地址操作。

## 调用顺序

1. 用 rk_iic dev = RK_IIC_INIT 初始化，调用 rk_iic_open。
2. rk_iic_get_status 获取协议版本和状态。
3. rk_iic_set_parameter 按低字节在前写入 4 个暂存寄存器，回读核对，提交后检查序号。
4. rk_iic_peek 返回 1 表示读到一个字节，0 表示空，-1 表示错误。
5. 本地处理成功后调用 rk_iic_consume 一次，释放邮箱；最后 rk_iic_close。

recv 一次只取一个字节。需要轮询时由应用层设置周期，不在库里忙等。
读寄存器使用 I2C_RDWR 的写索引+重复 START+读数据组合事务。

## 当前边界

调用需要单一拥有者，完整的参数提交和 peek/consume 序列不可与其他进程交错。
当前单字节邮箱没有消息序号；重复 consume 可能删除新到的数据。
commit/consume 总线错误后，操作是否已执行可能不确定，禁止盲目重试。
跨 FPGA 复位、丢包恢复和真正串口 FIFO 的可靠性协议留待下一阶段。
提交序号只表示寄存器接受参数，并不表示视频算法已在帧边界应用参数。

参考 Linux 官方 i2c-dev 文档：
https://www.kernel.org/doc/html/latest/i2c/dev-interface.html
