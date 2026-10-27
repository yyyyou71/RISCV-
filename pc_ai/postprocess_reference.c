/* 从已保存的六张头图检查参考后处理，无需重新执行72个卷积。
 * sigmoid_z/shr/SortEnt/cmp_ent直接来自原C；保留原detect_fwd的两次qsort和浮点框公式。
 * 这里的大数组只在PC运行，绝不编入RV32I固件。 */
#ifndef TRIDENT_SOURCE
#error "需要指定参考整数C模型"
#endif
#define main trident_original_main
#include TRIDENT_SOURCE
#undef main
#include "../csrc/software/ai_postprocess.h"

static FILE *memory;
static void read_at(uint32_t address,void *data,size_t bytes)
{
    if(fseek(memory,address,SEEK_SET) || fread(data,1,bytes,memory)!=bytes){fprintf(stderr,"reference read\n");exit(2);}
}
int main(int argc,char **argv)
{
    if(argc!=4)return 2;
    memory=fopen(argv[1],"rb");if(!memory)return 2;
    ai_post_config cfg;ai_post_head heads[AI_POST_MAX_HEADS];
    read_at((uint32_t)strtoul(argv[2],0,0),&cfg,sizeof(cfg));
    if(!cfg.head_count || cfg.head_count>AI_POST_MAX_HEADS)return 2;
    uint32_t total=0;
    for(uint32_t i=0;i<cfg.head_count;i++) {
        read_at(cfg.heads_addr+i*64,&heads[i],64);total+=heads[i].height*heads[i].width;
    }
    uint32_t classes=heads[0].classes,offset=0;
    float *boxes=calloc(total*4,sizeof(float)),*anch=calloc(total*2,sizeof(float)),*strd=calloc(total,sizeof(float));
    i32 *zall=calloc(total*classes,sizeof(i32));SortEnt *am=calloc(total,sizeof(SortEnt));
    if(!boxes || !anch || !strd || !zall || !am)return 2;
    for(uint32_t i=0;i<cfg.head_count;i++) {
        ai_post_head *h=&heads[i];uint32_t pixel_bytes=((classes+15)&~15u)*2;
        float s_box=ldexpf((float)h->box_multiplier,-(int)h->box_shift-16)/(float)h->stride;
        for(uint32_t a=0;a<h->height*h->width;a++) {
            i16 box[8],cls[AI_POST_MAX_CLASSES];
            read_at(h->box_addr+a*32,box,16);read_at(h->cls_addr+a*pixel_bytes,cls,pixel_bytes);
            for(uint32_t j=0;j<4;j++)boxes[(offset+a)*4+j]=box[j]*s_box;
            for(uint32_t c=0;c<classes;c++)zall[c*total+offset+a]=sigmoid_z((i32)shr((i64)cls[c]*h->logit_multiplier,(int)h->logit_shift));
            anch[(offset+a)*2]=(float)(a%h->width)+0.5f;anch[(offset+a)*2+1]=(float)(a/h->width)+0.5f;
            strd[offset+a]=(float)h->stride;
        }
        offset+=h->height*h->width;
    }
    for(uint32_t a=0;a<total;a++) {
        i32 mx=zall[a];for(uint32_t c=1;c<classes;c++)if(zall[c*total+a]>mx)mx=zall[c*total+a];
        am[a].v=mx;am[a].i=a;
    }
    qsort(am,total,sizeof(SortEnt),cmp_ent);
    uint32_t k=total<cfg.max_detections ? total:cfg.max_detections;
    SortEnt *flat=calloc(k*classes,sizeof(SortEnt));if(!flat)return 2;
    for(uint32_t i=0;i<k;i++)for(uint32_t c=0;c<classes;c++) {
        flat[i*classes+c].v=zall[c*total+am[i].i];flat[i*classes+c].i=i*classes+c;
    }
    qsort(flat,k*classes,sizeof(SortEnt),cmp_ent);
    uint32_t n=k*classes<cfg.max_detections ? k*classes:cfg.max_detections;
    FILE *f=fopen(argv[3],"w");if(!f)return 2;fputs("[",f);int first=1;
    for(uint32_t i=0;i<n;i++) {
        if((uint32_t)flat[i].v<cfg.threshold_q16)continue;
        uint32_t a=am[flat[i].i/classes].i,c=flat[i].i%classes;
        float x1=(anch[a*2]-boxes[a*4])*strd[a],y1=(anch[a*2+1]-boxes[a*4+1])*strd[a];
        float x2=(anch[a*2]+boxes[a*4+2])*strd[a],y2=(anch[a*2+1]+boxes[a*4+3])*strd[a];
        fprintf(f,"%s{\"anchor_id\":%u,\"class_id\":%u,\"score_q16\":%d,\"box\":[%.9g,%.9g,%.9g,%.9g]}",
            first ? "":",",a,c,flat[i].v,x1,y1,x2,y2);first=0;
    }
    fputs("]\n",f);fclose(f);fclose(memory);
    free(boxes);free(anch);free(strd);free(zall);free(am);free(flat);return 0;
}
