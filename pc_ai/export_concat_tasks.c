/* Concat期望值来自参考concat2，并导出一个完整C3模块用于CPU任务表对拍。 */
#define ADD_EXPORT_LIBRARY
#include "export_add_tasks.c"

static void direct_concat(int index){
    const int ca[16]={1,5,7,8,9,15,16,17,3,31,32,33,64,288,384,1};
    const int cb[16]={1,3,9,8,7,1,16,5,17,2,33,31,64,288,288,1};
    int h=index%4==0 ? 2:1,w=index%3==0 ? 5:3;
    Tensor a=t_alloc(ca[index],h,w),b=t_alloc(cb[index],h,w);
    for(int k=0;k<a.c*h*w;k++)a.d[k]=(i16)((int)(random_word()%65536)-32768);
    for(int k=0;k<b.c*h*w;k++)b.d[k]=(i16)((int)(random_word()%65536)-32768);
    a.d[0]=-32768;b.d[0]=32767;
    int alias=index==3;if(alias)memcpy(b.d,a.d,(size_t)a.c*h*w*2);
    Tensor y=concat2(&a,&b);u32 start=initial_count,gstart=golden_count;
    u32 ia=0x7f0,ib=alias ? ia:0x1fff0,oa=index==15 ? 0x1fffff00:0x807f0;
    emit_image(ia,&a,0x5555);if(!alias)emit_image(ib,&b,0x6666);
    int pitch=(y.c+15)&~15;u32 size=h*w*pitch*2;
    u8 guard[16];memset(guard,0xa5,16);emit_initial(oa-16,guard);memset(guard,0x5a,16);emit_initial(oa+size,guard);
    for(int p=0;p<h*w;p++)for(int c=0;c<pitch;c+=8){
        for(int j=7;j>=0;j--)fprintf(golden_file,"%04x",c+j<y.c ? (unsigned)(uint16_t)y.d[(size_t)(c+j)*h*w+p]:0);
        fputc('\n',golden_file);golden_count++;
    }
    // 同一个输入字跨多个输出字时应复用；不允许每个元素重新读DDR。
    u32 reads=(u32)h*w*(alias ? 1:((a.c+7)/8+(b.c+7)/8));
    u32 job[15]={(u32)h|((u32)w<<16),(u32)a.c|((u32)y.c<<16),reads<<16,ia,ib,0,oa,
        start,initial_count-start,gstart,size/16,0,0,4,(u32)b.c};
    put_words(job_file,job,15);
}
static void write_concat(FILE *f,int layer,int source_a,int source_b){
    fprintf(f,"%s{\"name\":\"layer%d\",\"op\":\"concat\",\"input\":\"",layer ? ",\n":"",layer);
    if(source_a<0)fputs("input",f);else fprintf(f,"layer%d",source_a);
    fputs("\",\"input_b\":\"",f);if(source_b<0)fputs("input",f);else fprintf(f,"layer%d",source_b);fputs("\"}",f);
}
#ifndef CONCAT_EXPORT_LIBRARY
int main(int argc,char **argv){
    if(argc!=2)return 2;load_bin(argv[1]);if(g_nconv!=72)return 2;
    initial_file=open_file("ddr/initial.mem","w");golden_file=open_file("ddr/golden.mem","w");job_file=open_file("ddr/jobs.mem","w");
    for(int i=0;i<16;i++)direct_concat(i);fclose(initial_file);fclose(golden_file);fclose(job_file);
    FILE *f=open_file("concat_counts.json","w");fprintf(f,"{\"layers\":16,\"initial\":%u,\"golden\":%u}\n",initial_count,golden_count);fclose(f);
    g_convs=realloc(g_convs,75*sizeof(*g_convs));if(!g_convs)return 2;
    add_custom(3,5,1,1,0,0,0,1);add_custom(3,17,1,1,0,0,0,1);add_custom(22,3,1,1,0,0,0,0);
    for(int net=0;net<3;net++){
        Tensor input=t_alloc(net==0 ? 64:net==1 ? 3:17,1,3),out[7];char path[80],json_name[80];
        for(int i=0;i<input.c*input.h*input.w;i++)input.d[i]=(i16)((int)(random_word()%2047)-1023);
        snprintf(path,80,"network%d.input.bin",net);write_tensor(path,&input,0);
        snprintf(json_name,80,"network%d.json",net);FILE *spec=open_file(json_name,"w");
        fprintf(spec,"{\"activation_bits\":16,\"input\":{\"shape\":[1,3,%d],\"data_file\":\"%s\"},\"layers\":[\n",input.c,path);
        int count=net==0 ? 7:net==1 ? 4:2;
        for(int layer=0;layer<count;layer++){
            if((net==0 && layer==5) || (net==1 && layer==2) || net==2){
                int a=net==0 ? 3:net==1 ? 0:layer-1,b=net==0 ? 4:net==1 ? 1:-1;
                out[layer]=concat2(a<0 ? &input:&out[a],b<0 ? &input:&out[b]);write_concat(spec,layer,a,b);
            }else if(net==0 && layer==3){
                AddRec *r=find_add("model.2.m.0.add");out[layer]=add_point(&out[0],&out[2],r->name);write_add(spec,layer,0,2,r);
            }else{
                const char *real[7]={"model.2.cv1","model.2.m.0.cv1","model.2.m.0.cv2",NULL,"model.2.cv2",NULL,"model.2.cv3"};
                const char *name=net==0 ? real[layer]:layer==0 ? "task.custom.0":layer==1 ? "task.custom.1":"task.custom.2";
                int source=net==0 ? (layer==4 ? -1:layer-1):(layer<2 ? -1:2);
                ConvRec *r=find_conv(name);out[layer]=conv_layer(source<0 ? &input:&out[source],name);
                write_layer(spec,net,layer,r,source,!(net==1 && layer==3));
            }
            snprintf(path,80,"network%d.layer%d.expected.bin",net,layer);write_tensor(path,&out[layer],1);
        }
        if(net==0){
            Tensor module=c3fpga_fwd(&input,2);
            if(module.c!=out[6].c || module.h!=out[6].h || module.w!=out[6].w ||
                memcmp(module.d,out[6].d,(size_t)module.c*module.h*module.w*2)!=0){fprintf(stderr,"C3 graph export mismatch\n");return 2;}
        }
        fputs("\n]}\n",spec);fclose(spec);
    }
    return 0;
}
#endif
