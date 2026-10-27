/* 在主机直接复用生产固件的描述符检查，不执行MMIO访问。 */
#include <stdio.h>
#include "../csrc/software/ai_runtime.c"
int main(int argc,char **argv){
    if(argc!=2)return 2;
    FILE *f=fopen(argv[1],"rb");if(!f)return 2;
    ai_model_header h;ai_task t;
    if(fread(&h,1,sizeof(h),f)!=sizeof(h) || h.magic!=AI_MODEL_MAGIC ||
        h.tasks_addr<h.arena_begin || fseek(f,(long)(h.tasks_addr-h.arena_begin),SEEK_SET))return 2;
    for(uint32_t n=0;n<h.task_count;n++){
        if(fread(&t,1,sizeof(t),f)!=sizeof(t))return 2;
        uint32_t code=validate_task(&h,&t);
        if(code){fprintf(stderr,"descriptor %u rejected: %u\n",n,code);return 2;}
    }
    fclose(f);printf("PASS descriptors=%u\n",h.task_count);return 0;
}
