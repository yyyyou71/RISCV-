/* MaxPool5期望值直接来自参考maxpool5；额外展开并核对完整SPPF模块。 */
#define CONCAT_EXPORT_LIBRARY
#include "export_concat_tasks.c"

static void direct_pool(int index){
    const int channels[16]={1,5,8,9,15,16,17,31,32,33,192,384,1,1,9,17};
    const int heights[16]={1,1,5,7,3,6,5,2,5,1,3,1,1,1,2,1};
    const int widths[16]={1,7,1,5,7,6,5,3,5,3,3,1,1,1,2,3};
    Tensor input=t_alloc(channels[index],heights[index],widths[index]);
    for(int k=0;k<input.c*input.h*input.w;k++){
        i16 v=(i16)((int)(random_word()%65536)-32768);
        if(index%3==1)v=(i16)(-1-(int)(random_word()%32768));
        if(index==0 || index==12)v=-32768;
        if(index==13)v=32767;
        input.d[k]=v;
    }
    Tensor y=maxpool5(&input);u32 start=initial_count,gstart=golden_count;
    u32 ia=index==12 ? 0x1fffffe0:index==14 ? 0:0x7f0;
    u32 oa=index==13 ? 0x1fffffe0:index==15 ? 0x1fffff00:0x807f0;
    emit_image(ia,&input,0x7fff); // 故意用大正数污染尾部通道，验证输出填充显式清零。
    int pitch=(input.c+15)&~15;u32 size=input.h*input.w*pitch*2;
    u8 guard[16];memset(guard,0xa5,16);emit_initial(oa-16,guard);
    if(oa+size<0x20000000u){memset(guard,0x5a,16);emit_initial(oa+size,guard);}
    for(int p=0;p<y.h*y.w;p++)for(int c=0;c<pitch;c+=8){
        for(int j=7;j>=0;j--)fprintf(golden_file,"%04x",c+j<y.c ? (unsigned)(uint16_t)y.d[(size_t)(c+j)*y.h*y.w+p]:0);
        fputc('\n',golden_file);golden_count++;
    }
    // 每个有效邻居、每组8通道只读一次；完全填充的通道组不读DDR。
    u32 neighbors=0;
    for(int yy=0;yy<input.h;yy++)for(int xx=0;xx<input.w;xx++)
        for(int ky=-2;ky<=2;ky++)for(int kx=-2;kx<=2;kx++)
            if(yy+ky>=0 && yy+ky<input.h && xx+kx>=0 && xx+kx<input.w)neighbors++;
    u32 reads=neighbors*((input.c+7)/8);
    u32 job[15]={(u32)input.h|((u32)input.w<<16),(u32)input.c|((u32)input.c<<16),reads<<16,
        ia,0,0,oa,start,initial_count-start,gstart,size/16,0,0,4,0};
    put_words(job_file,job,15);t_free(&input);t_free(&y);
}

static void write_pool(FILE *f,int layer,int source){
    fprintf(f,"%s{\"name\":\"layer%d\",\"op\":\"maxpool5\",\"input\":\"",layer ? ",\n":"",layer);
    if(source<0)fputs("input",f);else fprintf(f,"layer%d",source);fputs("\"}",f);
}

int main(int argc,char **argv){
    if(argc!=2)return 2;load_bin(argv[1]);if(g_nconv!=72 || g_nadd!=10)return 2;
    initial_file=open_file("ddr/initial.mem","w");golden_file=open_file("ddr/golden.mem","w");job_file=open_file("ddr/jobs.mem","w");
    for(int i=0;i<16;i++)direct_pool(i);fclose(initial_file);fclose(golden_file);fclose(job_file);
    FILE *f=open_file("maxpool_counts.json","w");fprintf(f,"{\"layers\":16,\"initial\":%u,\"golden\":%u}\n",initial_count,golden_count);fclose(f);
    g_convs=realloc(g_convs,74*sizeof(*g_convs));if(!g_convs)return 2;
    add_custom(3,17,1,1,0,0,0,1);add_custom(17,3,1,1,0,0,0,0);
    for(int net=0;net<3;net++){
        int h=net==1 ? 3:1,w=net==0 ? 1:net==1 ? 5:3;
        Tensor input=t_alloc(net==0 ? 384:net==1 ? 3:17,h,w),out[5];char path[80],json_name[80];
        for(int k=0;k<input.c*h*w;k++)input.d[k]=(i16)((int)(random_word()%2047)-1023);
        snprintf(path,80,"network%d.input.bin",net);write_tensor(path,&input,0);
        snprintf(json_name,80,"network%d.json",net);FILE *spec=open_file(json_name,"w");
        fprintf(spec,"{\"activation_bits\":16,\"input\":{\"shape\":[%d,%d,%d],\"data_file\":\"%s\"},\"layers\":[\n",h,w,input.c,path);
        int count=net==0 ? 5:net==1 ? 3:2;
        for(int layer=0;layer<count;layer++){
            if((net==0 && layer==1) || (net==1 && layer==1) || net==2){
                out[layer]=maxpool5(layer==0 ? &input:&out[layer-1]);write_pool(spec,layer,layer-1);
            }else if(net==0 && layer==2){
                out[layer]=concat2(&out[0],&out[1]);write_concat(spec,layer,0,1);
            }else if(net==0 && layer==4){
                AddRec *r=find_add("model.9.add");out[layer]=add_point(&input,&out[3],r->name);write_add(spec,layer,-1,3,r);
            }else{
                const char *name=net==0 ? (layer==0 ? "model.9.cv1":"model.9.cv2"):
                    (layer==0 ? "task.custom.0":"task.custom.1");
                ConvRec *r=find_conv(name);out[layer]=conv_layer(layer==0 ? &input:&out[layer-1],name);
                write_layer(spec,net,layer,r,layer-1,!(net==1 && layer==2));
            }
            snprintf(path,80,"network%d.layer%d.expected.bin",net,layer);write_tensor(path,&out[layer],1);
        }
        if(net==0){
            Tensor module=sppf_fwd(&input);
            if(module.c!=out[4].c || module.h!=out[4].h || module.w!=out[4].w ||
                memcmp(module.d,out[4].d,(size_t)module.c*module.h*module.w*2)!=0){fprintf(stderr,"SPPF graph export mismatch\n");return 2;}
        }
        fputs("\n]}\n",spec);fclose(spec);
    }
    return 0;
}
