#include "ai_postprocess.h"

/* 单模型检测入口。仍用AIR1传递模型地址；AIP1由加载端独立放到0x5000。
 * AI_POST_ONLY只供定向仿真：检测头已预装，跳过网络计算，生产入口不定义它。 */
int main(void)
{
    uint32_t request[8],entry[4];ai_run_result network;ai_post_result post;
    uint32_t code=ai_ddr_read(AI_BOOT_ADDR,request,32);if(code)return (int)(0x100+code);
    uint32_t list=request[3],report=request[4];
    if(request[0]!=AI_RUN_MAGIC || request[1]!=AI_ABI_VERSION || request[2]!=1 ||
       request[5] || request[6] || request[7])return 0x101;
    if((list|report)&15 || list<AI_BOOT_ADDR+32 || report<AI_BOOT_ADDR+32 ||
       (uint64_t)list+16>AI_POST_CONFIG_ADDR || (uint64_t)report+32>AI_POST_CONFIG_ADDR ||
       ((uint64_t)list+16>report && (uint64_t)report+32>list))return 0x102;
    code=ai_ddr_read(list,entry,16);if(code)return (int)(0x100+code);
    if(entry[1] || entry[2] || entry[3])return 0x101;
#ifdef AI_POST_ONLY
    network.code=0;network.failed_task=0xffffffffu;network.hardware_code=0;network.completed=0;
    network.cycles=0;network.issues=0;network.out_h=0;network.out_w=0;
#else
    ai_run_model(entry[0],&network);
#endif
    code=ai_ddr_write(report,(const uint32_t *)&network,32);if(code)return (int)(0x200+code);
    if(network.code)return 1;
    ai_postprocess(AI_POST_CONFIG_ADDR,entry[0],&post);
    code=ai_ddr_write(AI_POST_REPORT_ADDR,(const uint32_t *)&post,32);
    return code ? (int)(0x200+code):1;
}
