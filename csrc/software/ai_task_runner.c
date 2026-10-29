#include "ai_runtime.h"

/* 预装载仿真入口：测试台已写好模型包和 AIR1 请求。
   正式固件应在外部传输完成后进入调度；SPI 启动协商由后续集成接入。
   这里不解析模型框架，也不生成测试权重。 */
int main(void)
{
    uint32_t request[8],entry[4];
    ai_run_result result;
    uint32_t code=ai_ddr_read(AI_BOOT_ADDR,request,32);
    if(code)return (int)(0x100+code);
    uint32_t count=request[2],list=request[3],reports=request[4];
    if(request[0]!=AI_RUN_MAGIC || request[1]!=AI_ABI_VERSION || !count || count>AI_MAX_JOBS ||
       request[5] || request[6] || request[7])return 0x101;
    if((list|reports)&15 || list<AI_BOOT_ADDR+32 || reports<AI_BOOT_ADDR+32 ||
       list>=AI_MODEL_MIN || reports>=AI_MODEL_MIN ||
       list+count*16>AI_MODEL_MIN || reports+count*32>AI_MODEL_MIN ||
       (list<reports+count*32 && reports<list+count*16))return 0x102;
    for(uint32_t n=0;n<count;n++) {
        code=ai_ddr_read(list+n*16,entry,16);
        if(code)return (int)(0x100+code);
        if(entry[1] || entry[2] || entry[3])return 0x101;
        ai_run_model(entry[0],&result);
        /* 无致命故障时，错误也写入报告并继续下一份模型，以验证可恢复性。
           CPU 的退出值 1 表示请求列表处理完毕；每份模型的成功由报告 code=0 表示。 */
        code=ai_ddr_write(reports+n*32,(const uint32_t *)&result,32);
        if(code)return (int)(0x200+code);
    }
    return 1;
}
