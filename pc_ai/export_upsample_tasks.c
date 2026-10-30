/* 2倍最近邻上采样期望值来自原C；补充包含全部五类算子的任务网络。 */
#define CONCAT_EXPORT_LIBRARY
#include "export_concat_tasks.c"

static void direct_up(int index){
    const int channels[16]={1,5,8,9,15,16,17,31,32,33,144,288,384,672,1,9};
    const int heights[16]={1,1,5,2,3,1,2,2,1,2,1,1,1,1,1,1};
    const int widths[16]={1,5,1,3,2,3,2,1,3,2,1,1,1,1,1,3};
    Tensor input=t_alloc(channels[index],heights[index],widths[index]);
    for(int k=0;k<input.c*input.h*input.w;k++)input.d[k]=(i16)((int)(random_word()%65536)-32768);
    input.d[0]=-32768;if(input.c*input.h*input.w>1)input.d[1]=32767;
    Tensor y=upsample2x(&input);u32 start=initial_count,gstart=golden_count;
    u32 ia=index==14 ? 0x1fffffe0:index==13 ? 0:0x7f0;
    u32 oa=index==15 ? 0x1ffffe80:0x807f0;
    emit_image(ia,&input,0x5555);
    int pitch=(input.c+15)&~15;u32 size=y.h*y.w*pitch*2;
    u8 guard[16];memset(guard,0xa5,16);emit_initial(oa-16,guard);
    if(oa+size<0x20000000u){memset(guard,0x5a,16);emit_initial(oa+size,guard);}
    for(int p=0;p<y.h*y.w;p++)for(int c=0;c<pitch;c+=8){
        for(int j=7;j>=0;j--)fprintf(golden_file,"%04x",c+j<y.c ? (unsigned)(uint16_t)y.d[(size_t)(c+j)*y.h*y.w+p]:0);
        fputc('\n',golden_file);golden_count++;
    }
    // 一次源字读取供四个输出像素使用；完全填充的通道组不读DDR。
    u32 reads=(u32)input.h*input.w*((input.c+7)/8);
    u32 job[15]={(u32)input.h|((u32)input.w<<16),(u32)input.c|((u32)input.c<<16),reads<<16,
        ia,0,0,oa,start,initial_count-start,gstart,size/16,0,0,4,0};
    put_words(job_file,job,15);t_free(&input);t_free(&y);
}

static void write_unary(FILE *f,int layer,int source,const char *op){
    fprintf(f,"%s{\"name\":\"layer%d\",\"op\":\"%s\",\"input\":\"",layer ? ",\n":"",layer,op);
    if(source<0)fputs("input",f);else fprintf(f,"layer%d",source);fputs("\"}",f);
}

int main(int argc,char **argv){
    if(argc!=2)return 2;load_bin(argv[1]);if(g_nconv!=72 || g_nadd!=10)return 2;
    initial_file=open_file("ddr/initial.mem","w");golden_file=open_file("ddr/golden.mem","w");job_file=open_file("ddr/jobs.mem","w");
    for(int i=0;i<16;i++)direct_up(i);fclose(initial_file);fclose(golden_file);fclose(job_file);
    FILE *f=open_file("upsample_counts.json","w");fprintf(f,"{\"layers\":16,\"initial\":%u,\"golden\":%u}\n",initial_count,golden_count);fclose(f);
    g_convs=realloc(g_convs,74*sizeof(*g_convs));if(!g_convs)return 2;
    add_custom(3,17,1,1,0,0,0,1);add_custom(34,3,1,1,0,0,0,0);
    g_adds=realloc(g_adds,11*sizeof(*g_adds));if(!g_adds)return 2;
    AddRec *ar=&g_adds[g_nadd++];memset(ar,0,sizeof(*ar));strcpy(ar->name,"add.custom.0");ar->bits=16;ar->multA=ar->multB=1;
    for(int net=0;net<3;net++){
        int h=net==0 ? 2:1,w=net==0 ? 3:net==1 ? 1:3;
        Tensor input=t_alloc(net==0 ? 3:net==1 ? 672:9,h,w),out[6];char path[80],json_name[80];
        for(int k=0;k<input.c*h*w;k++)input.d[k]=net==2 ? (i16)((int)(random_word()%65536)-32768):(i16)((int)(random_word()%2047)-1023);
        snprintf(path,80,"network%d.input.bin",net);write_tensor(path,&input,0);
        snprintf(json_name,80,"network%d.json",net);FILE *spec=open_file(json_name,"w");
        fprintf(spec,"{\"activation_bits\":16,\"input\":{\"shape\":[%d,%d,%d],\"data_file\":\"%s\"},\"layers\":[\n",h,w,input.c,path);
        int count=net==0 ? 6:2;
        for(int layer=0;layer<count;layer++){
            const Tensor *previous=layer==0 ? &input:&out[layer-1];
            if(net==0 && layer==1){
                out[layer]=maxpool5(previous);write_unary(spec,layer,layer-1,"maxpool5");
            }else if((net==0 && layer==2) || (net==1 && layer==0) || net==2){
                out[layer]=upsample2x(previous);write_unary(spec,layer,layer-1,"upsample2x");
            }else if(net==0 && layer==3){
                out[layer]=add_point(&out[2],&out[2],ar->name);write_add(spec,layer,2,2,ar);
            }else if(net==0 && layer==4){
                out[layer]=concat2(&out[2],&out[3]);write_concat(spec,layer,2,3);
            }else{
                const char *name=net==1 ? "model.13.cv1":layer==0 ? "task.custom.0":"task.custom.1";
                ConvRec *r=find_conv(name);out[layer]=conv_layer(previous,name);
                write_layer(spec,net,layer,r,layer-1,!(net==0 && layer==5));
            }
            snprintf(path,80,"network%d.layer%d.expected.bin",net,layer);write_tensor(path,&out[layer],1);
        }
        fputs("\n]}\n",spec);fclose(spec);
    }
    return 0;
}
