/* 主机运行生产后处理代码；用文件模拟DDR窗口，便于数值、越界和故障检查。 */
#include <stdio.h>
#include <stdlib.h>
#include "../csrc/software/ai_postprocess.h"

static FILE *memory;
static unsigned reads,writes,fail_read,fail_write;
uint32_t ai_ddr_read(uint32_t address,uint32_t *data,uint32_t bytes)
{
    if(!bytes || bytes>256 || (address|bytes)&15 || (uint64_t)address+bytes>AI_DDR_BYTES)return AI_BAD_RANGE;
    if(++reads==fail_read)return AI_DDR_ERROR;
    if(fseek(memory,address,SEEK_SET) || fread(data,1,bytes,memory)!=bytes)return AI_DDR_ERROR;
    return AI_OK;
}
uint32_t ai_ddr_write(uint32_t address,const uint32_t *data,uint32_t bytes)
{
    if(!bytes || bytes>256 || (address|bytes)&15 || address<AI_POST_OUTPUT_MIN ||
       (uint64_t)address+bytes>AI_MODEL_MIN)return AI_BAD_RANGE;
    if(++writes==fail_write)return AI_DDR_ERROR;
    if(fseek(memory,address,SEEK_SET) || fwrite(data,1,bytes,memory)!=bytes)return AI_DDR_ERROR;
    return AI_OK;
}
int main(int argc,char **argv)
{
    if(argc<5 || argc>7)return 2;
    memory=fopen(argv[1],"r+b");if(!memory)return 2;
    if(argc>5)fail_read=(unsigned)strtoul(argv[5],0,0);
    if(argc>6)fail_write=(unsigned)strtoul(argv[6],0,0);
    ai_post_result r;uint32_t code=ai_postprocess((uint32_t)strtoul(argv[2],0,0),(uint32_t)strtoul(argv[3],0,0),&r);
    if(code!=r.code)return 3;
    fclose(memory);FILE *f=fopen(argv[4],"wb");if(!f)return 2;
    int ok=fwrite(&r,1,sizeof(r),f)==sizeof(r);fclose(f);
    return ok ? 0:2;
}
