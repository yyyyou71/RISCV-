/* 在独立进程中调用参考整数模型，不修改材料目录。
 * 完整候选框输出为 JSON，同时导出第一层原始 int16 数据供独立对拍。
 */
#ifndef TRIDENT_SOURCE
#error "请通过验证脚本指定 TridentVision 的 rearch_fixed.c"
#endif
#define main trident_original_main
#include TRIDENT_SOURCE
#undef main

int main(int argc,char **argv)
{
    if(argc!=5){fprintf(stderr,"usage: bridge weights.bin input.npy result.json first_conv.bin\n");return 2;}
    load_bin(argv[1]);
    Tensor input=npy_load(argv[2]);
    if(input.c!=3 || input.h!=96 || input.w!=96){fprintf(stderr,"需要 3x96x96 的 CHW INT16 输入\n");return 2;}
    Det dets[300];
    int count=forward_fixed(&input,dets,300);
    FILE *f=fopen(argv[3],"w");
    if(!f){perror("result");return 2;}
    fprintf(f,"{\"point_count\":%d,\"q13_clamps\":%lld,\"max_abs_acc\":%lld,\"detections\":[",g_npts,(long long)g_sat_clamp,(long long)g_max_acc);
    for(int i=0;i<count;i++)fprintf(f,"%s{\"class_id\":%d,\"score\":%.9g,\"box\":[%.9g,%.9g,%.9g,%.9g]}",
        i ? ",":"",dets[i].cls,dets[i].score,dets[i].x1,dets[i].y1,dets[i].x2,dets[i].y2);
    fprintf(f,"]}\n");fclose(f);
    for(int i=0;i<g_npts;i++)if(strcmp(g_pts[i].name,"model.0")==0){
        Tensor *t=&g_pts[i].t;
        f=fopen(argv[4],"wb");if(!f){perror("first_conv");return 2;}
        size_t elements=(size_t)t->c*t->h*t->w;
        size_t written=fwrite(t->d,sizeof(i16),elements,f);fclose(f);
        return written==elements ? 0:2;
    }
    fprintf(stderr,"第一层输出未注册\n");return 2;
}
