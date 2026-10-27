# RV32I检测后处理

日期：2026-10-27。状态：定点后处理、原C规则比较、RV32I/DDR定向仿真及小规模计算后解码闭环通过。
用户此前已通过完整99条张量任务；本次准备了“99条任务+CPU后处理”的入口，长仿真尚未运行。

## 1. 处理流程与适用范围

`csrc/software/ai_postprocess.c`是生产代码，主机检查与RV32I编译使用同一份实现。
它通过`ai_ddr_read/ai_ddr_write`访问现有跨时钟DDR窗口，不直接解引用DDR地址。

```text
AI执行完网络，六张检测头留在DDR
  → CPU读取AIP1描述符和sigmoid表
  → 第一遍分类图：每个位置求最大分数，选Top-K位置
  → 第二遍选中位置：展开所有类别，选Top-K候选
  → 保留分数≥阈值的候选，读取对应l/t/r/b
  → 定点解码框坐标，将32字节记录写回DDR
```

本模型为one2one、reg_max=1的l/t/r/b头，沿用原C的两次Top-K，不增加NMS或objectness分支。
支持1..4组框/分类头、各组相同的1..128个类别、最大300条结果，输入高宽各≤4096、总位置≤65535。
这属于特定检测头格式的参数化解码；DFL等其它检测头需要另行实现解码。

分数降序；第一次同分按全局位置索引升序，第二次同分按“第一次排序名次×类别数+类别索引”升序。
允许同一位置输出多个类别。两个有界堆分别保存最多300个位置和候选，不分配全分类矩阵。
sigmoid表经过单调性检查，各类别共用正的logit乘数，因此第一遍先求最大原始码再查表，和原C逐类别查表后求最大等价。

## 2. 数值与内存

- 分类：原始INT16×multL，经原RHU规则右移，再用原32段sigmoid表插值，输出Q0.16。
- 坐标：有符号32位Q16，`实际像素=码值/65536`。s_box从原float32精确转换成整数乘数/右移，不在CPU运行浮点。
- 框公式：中心为`(x+0.5,y+0.5)×stride`，减去l/t距离、加上r/b距离。
- 阈值为包含边界的`score_q16>=threshold_q16`，默认16384，即0.25；设0可核对原C完整Top-300。
- 坐标对应模型输入尺寸，保留负数和越界数。显示/通信端后续根据原图尺寸映射、裁剪。

分类每次只读一个位置的填充通道，最多256字节；框图物理步长32字节，只读其前16字节。
第二遍重读入选位置的分类通道，以DDR访问换取有限CPU RAM。没有malloc、qsort或浮点运行库。
源码与ABI仍支持更换头地址、形状、类别数、尺度、量化系数和LUT；这些均装载到DDR，不编译进ROM。

完整检测固件实测text=8956字节、data=0、bss=0；只跑后处理的定向固件text=8980字节。
GCC栈报告中`ai_postprocess`自身帧5824字节、入口main自身128字节，另有驱动/辅助函数调用帧；这不是完整调用栈峰值。
构建脚本检查32KiB ROM、64KiB RAM，并为检测固件额外预留16KiB栈空间，拒绝意外链接浮点或动态分配符号。

默认96输入共有189个位置。阈值0.25时，主机生产代码读取390次DDR窗口、共61,152字节，输出6条、192字节；
这些是当前诊断输入的工作量与输出数，不是识别精度或实板性能结论。

## 3. DDR协议

AIP1是独立侧描述符，不更改AIM1模型或AIR1请求。检测入口`ai_detection_runner.c`目前只接受一个AIR1模型请求。
模型地址还须与AIP1中的model_addr一致；所有头图必须位于模型工作区内。

| 地址 | 内容 |
| --- | --- |
| 0x1000 / 0x2000 | 原AIR1启动请求 / 单项模型地址列表 |
| 0x4000 | 原32字节网络执行报告 |
| 0x5000 | 64字节AIP1头 |
| 0x5040 | 32字节后处理报告 |
| 0x5100 | 每组64字节检测头描述符 |
| 0x5200 | 32个Y与32个DY，各uint32，共256字节 |
| 0x8000 | 每条32字节的检测结果，最多9600字节 |
| 0x10000起 | 原模型包，包括输入、权重及所有中间图 |

头的16个uint32依次为：

```text
magic=0x31504941, version=1, header_bytes=64, head_bytes=64
head_count, heads_addr, threshold_q16, max_detections
output_addr, output_bytes, model_addr, lut_addr
input_h, input_w, flags=0, reserved=0
```

每组头的16个uint32依次为：

```text
box_addr, cls_addr, height, width
classes, stride, logit_multiplier, logit_shift
box_multiplier, box_shift, reserved[6]=0
```

`distance_pixel_q16=RHU(raw_int16*box_multiplier,box_shift)`。
框/分类物理布局仍为HWC-align16(C)、小端INT16；框逻辑C=4。
CPU先检查全部头、范围、系数和保留字段，再开始扫描，元数据错误时不写检测记录。

检测记录依次为：

```text
int32 x1_q16, y1_q16, x2_q16, y2_q16
uint32 score_q16, class_id, anchor_id, reserved=0
```

后处理报告的8个uint32依次为：`code,count,anchors,selected_anchors,read_calls,read_bytes,written,reserved`。
错误码沿用ai_runtime.h。count/written只统计已成功写回的记录；读取失败或部分写回后报错时，调用者须先检查code。
网络失败时入口仅写网络报告并退出，不继续后处理；后处理成功与否须检查0x5040，不能只看tohost退出值1。

## 4. 已完成的验证

```bash
make test-ai-postprocess
# 只做主机数值/异常检查：
python3 pc_ai/verify_ai_postprocess.py --host-only
```

产物在`pc_ai/outputs/ai_postprocess/`，总报告为`verification.json`。

- 真实六张C黄金头图：默认阈值、阈值0、空结果阈值、Top-7，共4组。
  最大300条时还与已经保存的原始forward_fixed检测结果核对，未重新计算卷积。
- 合成矩形、多尺度、17类尾填充、全部同分、400位置截取300位置、128类最大窗口，共4组。
- 参考检查使用原C的shr、sigmoid_z、SortEnt/cmp_ent，并保留detect_fwd的浮点框公式与两次qsort。
  置信度、类别、anchor及排序逐项完全一致；真实头图坐标误差最大约0.00000768像素，验收界限1/256像素。
- 9种非法元数据、2处读错误注入和第二次写错误注入，共12项拒绝/部分写回检查。
- 真实RV32I读取10个位置、17类的合成头图，写回7条结果；Verilator与Icarus均检查4188个DDR字。
- CPU约71.43MHz、DDR用户时钟约166.67MHz并随机停顿的同一后处理用例通过。
- 最后一个头保留字段非法的真实CPU用例，返回AI_BAD_TASK、零记录写回；包括输出毒值和哨兵检查。
- 完整检测固件先调度一个真实卷积生成分类头，再执行CPU后处理：4219字、240个MAC issue、7条记录，通过。

仿真检查器将CPU写入限制到网络报告、后处理报告和顺序检测记录，其余只读资产、头图及哨兵逐字比较。
测试台从CPU实际写回的DDR区导出`cpu_detections.mem`，脚本生成`cpu_detections.bin/json`。
`detections.json`是主机期望值；`cpu_detections.json`才来自CPU仿真输出。

## 5. 下一次完整检测仿真

需已有匹配当前输入的99份C黄金值。以下长任务由用户运行：

```bash
python3 pc_ai/prepare_trident_network.py --segment 0:99 --postprocess --simulator verilator --run
```

不加`--run`仅准备。目录为`segments/000_099_detection/`，保留原`000_099/`已通过记录。
与先前完整张量仿真相比，这次末尾将由CPU实际扫描头图、筛选、写回框，再比较输出。
默认诊断渐变图应有6条结果；预期日志同时包含`PASS ai_network ... tasks=99 ...`及`PASS ai_postprocess records=6`。

`result_verilator.json`中的full_tensor_graph与full_detection_network分别表示完整张量计算和包含CPU框输出的仿真；
这不包含SPI加载、真实图片精度验收、显示画框或上板。

供后续外部加载端使用的文件：`request_detection.bin`为DDR地址0处的64KiB启动/后处理区，
原`model.bin`仍加载到0x10000。固件用本目录的runner镜像。
`postprocess_config.bin`、`postprocess_heads.bin`和`postprocess_lut.bin`也独立导出。
`ddr_image.bin`仅供主机参考检查，含C黄金头图，不用作板级模型装载文件。
