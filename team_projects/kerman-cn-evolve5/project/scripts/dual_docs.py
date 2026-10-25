"""Generate the final measured-results document from checked DUAL1 JSON."""
import json
from pathlib import Path
from regress import PROJECT as P
s=json.loads((P/'reports/summary.json').read_text());r=json.loads((P/'release.json').read_text())
assert s['status']=='passed_offline' and r['status']=='offline_verified_board_pending'
lines=['# DUAL1 实现、验证与性能报告','',
'2026-10-22完成离线验证，2026-10-23整理发布，实板待验收。基于FRONT1的受限顺序双发射已实现，三种25MHz实现均满足原始时序预算。没有新的正式CoreMark/MHz成绩。','',
'## 1. 实际实现','',
'五级流水、顺序执行、顺序退休；第一槽完整RV32IM+Zicsr，第二槽仅合法RV32I ALU/LUI/AUIPC。同组RAW及非x0 WAW退为单发射；WAR允许。两条共同等待访存或乘除法，较老指令异常会取消第二条。控制流和FENCE不配对，CSR/系统指令另有流水串行化。中断在组边界进入。没有ROB、寄存器重命名、乱序、多访存端口或推测性数据写入。','',
'双字I-Cache只在同一行的命中时返回第二字；行尾、miss、旁路退为单字。四项FIFO支持每拍最多两字进入和两条消费。ROM/RAM仍各32KiB，I/D Cache逻辑容量各1KiB。详见[架构说明](架构与验证计划.md)。','',
'## 2. 相同固件下的性能','',
'三配置使用完全相同的18872字节DUAL1_BOARD固件、GCC 10.2.0、-O2、RV32IM+Zicsr、25MHz。官方CoreMark算法文件未修改，构建记录检查其哈希；编译参数一致，未链接预编译算术库。1024轮启动微基准在CoreMark计时区间外。','',
'下表为各8次迭代的RTL仿真，performance退休2528167条，validation退休2531693条，各配置一致。所有标准CRC正确；不足10秒，score_valid=0。加速比是相同工作量的周期比较，不能当作正式赛题成绩。','',
'| 配置 | performance周期 | validation周期 | 相对scalar加速 | performance IPC | LUT | FF |',
'|---|---:|---:|---:|---:|---:|---:|']
for x in s['comparison']:
    lines.append(f"| {x['config']} | {x['performance_cycles']} | {x['validation_cycles']} | {(x['speedup_p']-1)*100:.3f}% / {(x['speedup_v']-1)*100:.3f}% | {x['coremark_ipc']:.4f} | {x['luts']} | {x['registers']} |")
dual=s['comparison'][2]
lines+=['',f"dual比scalar快{(dual['speedup_p']-1)*100:.2f}%/{(dual['speedup_v']-1)*100:.2f}%，但LUT增加{(dual['area_ratio']-1)*100:.2f}%。同频率下每LUT工作效率为标量版的{dual['relative_work_per_cycle_per_lut']*100:.2f}%，因此dual适合速度优先对照；scalar继续保留为面积效率对照。默认新包选择dual用于验证本阶段功能，不代表已把旧实板基线替换为dual。",'',
'仅加宽取指的wide_single收益约0.34%，不能代替实际增加执行槽。双发射CoreMark的IPC仍低于1，因为大量控制流、相关指令、访存与除法等待不会被第二槽消除。独立ALU微基准的1.8817 IPC证明的是有足够独立指令时的双发射能力。','',
'微基准三版均退休34818条：scalar34886周期、wide_single34872周期；dual18503周期、16377个退休对。周期窗口含固定CSR开销，未作减开销美化。performance 8次迭代中dual第二槽实际退休524589条，占全部退休约20.75%；有120139次同对RAW拒绝，1278520次类型／错误限制拒绝。数据来自dual_metrics.csv，硬件累计计数与独立观察器逐区间相互核对。','',
'原始性能证据：`reports/final_coremark/<配置>/coremark_uart.txt`、timer_intervals.csv、bus_metrics.csv、front_metrics.csv、bp_stats.csv、dual_metrics.csv。初始冻结FRONT1固件和最终DUAL1固件分别比较，不混用不同二进制周期；累计36次短CoreMark运行。','',
'## 3. 验证范围','',
'| 类别 | 已通过证据 |',
'|---|---|',
'| RV32I双发射差分 | 469场景，233261个有序退休包，40/40指令类型，62433次第二槽退休 |',
'| RV32IM差分 | 160场景，74816包，16001次第二槽退休，包含上游8类M指令测试 |',
'| 明确双槽相关及取消 | 88场景，668包，256次第二槽退休；RAW/WAW/WAR/x0、M0/M1/W0/W1相关、load/store伙伴、M伙伴、故障取消与成对复位 |',
'| 精确异常／中断 | dual_final、aggressive_dual各69场景，含实际配对后的IRQ和较老load/store故障抑制第二槽 |',
'| 寄存器堆 | 6000组四读两写、同拍旁路、x0、WAW优先级及复位 |',
'| 双宽Cache | 10组配置，边界、错误、复位、disabled及单字回填 |',
'| 双宽FIFO | 18组配置×6000周期=108000周期；深度2/4/8、直通开关、双取指／双消费组合 |',
'| 取指错误与预测 | 96项第一／第二字取指错误 + 12项预测／RAS／元数据保留场景 |',
'| 固件集成 | 三配置q/w/p/v，统一固件的2/8次迭代比较，M和DUAL启动自检，timer低字回绕与实际计时点核对 |',
'| 主机工具 | 3配置正向、26种负向日志变异；11种分包、复位、超时、错误及部分日志保留场景；通用日志套件50方法通过，9个仅适用于历史CACHE3的报告用例显式跳过 |','',
'使用自建Python参考模型逐条对比退休、最终寄存器和存储副作用；不声称官方RISC-V认证。主机工具的长时间正向样本是明确标注的合成测试夹具，不是实板成绩。旧阶段测试数据不冒充本阶段重测。','',
'## 4. PDS映射与时序','',
'器件PG2L100H-6IFBG484，PDS 2022.2-SP6.1。保持原40ns时钟及0.200ns时钟不确定度；报告setup含工具0.050ns jitter，实际0.250ns，hold0.200ns。原异步引脚例外保持不变，没有新增内部假路径屏蔽。所有发布版本均4个GTP_APM_E2 DSP、16个DRM36K（ROM8/RAM8）、零锁存器。ROM8192个字从实际映射INIT反解并与固件逐字比较。','',
'| 配置 | setup slow/fast余量ns | hold slow/fast余量ns | Cache物理数据bank | 成功seed |',
'|---|---|---|---:|---:|']
for name in ('scalar','wide_single','dual'):
    v=r['variants'][name];a=v['audit'];t=a['timing'];b=json.loads((P/v['pds_report']).read_text())
    lines.append(f"| {name} | {t['setup_slow']['worst_slack_ns']:.3f} / {t['setup_fast']['worst_slack_ns']:.3f} | {t['hold_slow']['worst_slack_ns']:.3f} / {t['hold_fast']['worst_slack_ns']:.3f} | {a['cache_distributed_byte_banks']} | {b['prepared']['route_seed']} |")
lines+=['',
'双字配置多8个128×8分布式RAM数据bank作为I-Cache第二读口副本，Cache物理数据位24576，逻辑有效容量仍16384位。DSP数量保持4，没有复制乘除法器。LUT/FF列采用综合报告口径，各配置一致。时序结果只证明25MHz约束通过；没有实际扫描最高可用频率。','',
'wide_single首次seed1存在hold违例：slow -0.137ns（4端点）、fast -0.150ns（17端点）；seed6重试为-0.229/-0.215ns，仍未通过。保留`reports/pds/wide_single`及`s6_wide_single`失败报告，未发布这些位流。后续重试提高物理实现保持修复目标，但时钟约束不变；发布以release.json所引用的成功报告为准。','',
'测试过程中还发现过机器态测试台未打开I-Cache burst接口、FIFO不可达覆盖要求、Verilog测试模型函数隐式全局输入未触发重求值；均修复测试模型并重新通过，旧失败目录保留。不能把这些早期失败结果当作最终通过，也不隐藏失败尝试。','',
'## 5. 发布文件及后续','',
'三份位流、便携PDS工程、同一固件、原始验证报告和完整SHA-256清单一同发布。所有七套旧封存工程在发布前逐文件校验未变。','',
'| 配置 | 位流SHA-256 |', '|---|---|']
for name in ('scalar','wide_single','dual'):lines.append(f"| {name} | `{r['variants'][name]['sha256']}` |")
lines+=['',f"共同firmware.bin SHA-256：`{r['firmware_bin_sha256']}`。",'',
'下一步按[上板验收说明](上板验收说明.md)下载并核对身份／启动自检、三轮完整2048次两套种子、真实KEY0复位及原始日志。真实片上抓波、长时压力、最高频率、最终应用系统仍在后续计划中。RV32IM扩展能否参与赛题对应性能评分尚待确认。','']
(P/'docs/实现验证与性能报告.md').write_text('\n'.join(lines),encoding='utf-8')
print('DUAL1_DOCUMENTS_WRITTEN')
