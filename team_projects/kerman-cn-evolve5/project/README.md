# EVOLVE5：顺序双发射性能优化

本阶段完成新GCC、两槽控制流/访存/乘法、精确部分提交、低延迟MUL和快速store命令，以及预测器比较。ISA仍为RV32IM+Zicsr，25MHz；实板待验证。

- [实现验证与IPC报告](docs/实现验证与IPC报告.md)
- [上板验收说明](docs/上板验收说明.md)
- reports/summary.json：按原始timer、退休和UART证据重算的结果。
- release.json：仅引用原时序约束通过的位流。
- reference/phases：编译及各硬件步骤的历史对照，失败候选保留。

发布配置balanced为BTB32/RAS0，speed为BTB256/RAS8；两者使用同一份冻结GCC15 O2+LTO固件，程序BUILD仍为EVOLVE1_BOARD。用IMPL_ID及FRONT_CFG核对硬件。

默认Python为C:\Users\LZM\AppData\Local\Programs\Python\Python312\python.exe。新GCC安装位置及官方校验见reference/gcc15_install.json；GCC二进制不打包，不改系统PATH。可运行scripts/fetch_gcc15.py按官方固定版本下载并校验，再用build_coremark.py --gcc <GCC15路径> --optimization O2 --extra-flag=-flto构建同参数固件。PDS/Vivado使用原版本，PDS本机license不在包内。

校验运行scripts/verify_package.py。仿真入口scripts/coremark_regress.py，显式指定--config mul_pair或mul_pair_combo、--firmware-dir reference/frozen_evolve1_lto、--measure-iterations 8、--profile。在新副本复现，保留本包原始证据。

硬件验证入口：scripts/regress.py --suite all --config mul_pair_combo；scripts/m_core_regress.py --config mul_pair_combo；scripts/lsu_pair_regress.py --config mul_pair_combo；scripts/mul_slot_regress.py；scripts/machine_regress.py --config mul_pair_combo --m-enable 1。构建目录和报告目录可通过相应脚本参数显式指定。

PDS复现使用scripts/dual_pds.py --config mul_pair_combo --firmware-dir reference/frozen_evolve1_lto，并采用release.json对应build.json记载的seed、保持修复参数。pds_projects内有相对路径的便携工程。不能把退出0或生成sbit当成时序通过，必须执行完整audit_pds.py审计。

部分历史辅助脚本及测试保留追溯，旧默认配置不是本版发布入口。当前主机验收用scripts/verify_dual_log.py（已适配EVOLVE5）和scripts/run_board_coremark.ps1，详见上板说明。
