/* 复用C导出工具；ADD期望值直接调用参考add_point，包含独立算子及残差网络。 */
#define W8A16_EXPORT_LIBRARY
#include "export_w8a16_tasks.c"

static unsigned unit_count,initial_count,golden_count;
static FILE *unit_file,*initial_file,*golden_file,*job_file;
static void put_words(FILE *f,const u32 *v,int n){for(int i=n-1;i>=0;i--)fprintf(f,"%08x",v[i]);fputc('\n',f);}
static void emit_unit(i16 a,i16 b,u32 ma,u32 sa,u32 mb,u32 sb,i16 expected,int error){
    u32 v[6]={(u32)(uint16_t)a|((u32)(uint16_t)b<<16),ma,sa,mb,sb,(u32)(uint16_t)expected|((u32)error<<16)};
    put_words(unit_file,v,6);unit_count++;
}
static void emit_initial(u32 address,const u8 *data){
    fprintf(initial_file,"%08x",address);for(int i=15;i>=0;i--)fprintf(initial_file,"%02x",data[i]);fputc('\n',initial_file);initial_count++;
}
static void emit_image(u32 address,const Tensor *t,uint16_t poison){
    int pitch=(t->c+15)&~15;
    for(int p=0;p<t->h*t->w;p++)for(int c=0;c<pitch;c+=8){
        u8 b[16];for(int j=0;j<8;j++){uint16_t v=c+j<t->c ? (uint16_t)t->d[(size_t)(c+j)*t->h*t->w+p]:poison;b[j*2]=v;b[j*2+1]=v>>8;}
        emit_initial(address+(p*pitch+c)*2,b);
    }
}
static void create_direct(int index,AddRec *r){
    const int channels[15]={1,5,8,9,15,16,17,31,32,33,1,17,9,3,1};
    Tensor a=t_alloc(channels[index],index%4==0 ? 2:1,index%3==0 ? 5:3),b=t_alloc(channels[index],a.h,a.w);
    for(int i=0;i<a.c*a.h*a.w;i++){
        a.d[i]=(i16)((int)(random_word()%65536)-32768);b.d[i]=(i16)((int)(random_word()%65536)-32768);
        if(index==11){a.d[i]=1;b.d[i]=1;}
    }
    Tensor y=add_point(&a,&b,r->name);u32 start=initial_count,gstart=golden_count;
    u32 ia=0x7f0,ib=0x1fff0,qa=0x50000,oa=index==14 ? 0x1fffff00:0x807f0;
    emit_image(ia,&a,0x5555);emit_image(ib,&b,0x6666);
    u8 q[16];u32 v[4]={(u32)r->multA,(u32)r->shiftA,(u32)r->multB,(u32)r->shiftB};
    for(int i=0;i<4;i++)for(int j=0;j<4;j++)q[i*4+j]=(u8)(v[i]>>(j*8));emit_initial(qa,q);
    int pitch=(y.c+15)&~15;u32 size=y.h*y.w*pitch*2;
    u8 guard[16];memset(guard,0xa5,16);emit_initial(oa-16,guard);memset(guard,0x5a,16);emit_initial(oa+size,guard);
    for(int p=0;p<y.h*y.w;p++)for(int c=0;c<pitch;c+=8){
        uint16_t values[8];for(int j=0;j<8;j++)values[j]=c+j<y.c ? (uint16_t)y.d[(size_t)(c+j)*y.h*y.w+p]:0;
        for(int j=7;j>=0;j--)fprintf(golden_file,"%04x",values[j]);fputc('\n',golden_file);golden_count++;
    }
    u32 job[15]={(u32)a.h|((u32)a.w<<16),(u32)a.c|((u32)a.c<<16),0,ia,ib,0,oa,start,initial_count-start,gstart,size/16,0,qa,4,0};
    put_words(job_file,job,15);
}
static void write_add(FILE *f,int layer,int source_a,int source_b,const AddRec *r){
    fprintf(f,"%s{\"name\":\"layer%d\",\"op\":\"add\",\"input\":\"",layer ? ",\n":"",layer);
    if(source_a<0)fputs("input",f);else fprintf(f,"layer%d",source_a);
    fputs("\",\"input_b\":\"",f);if(source_b<0)fputs("input",f);else fprintf(f,"layer%d",source_b);
    fprintf(f,"\",\"quant_add\":[%d,%d,%d,%d]}",r->multA,r->shiftA,r->multB,r->shiftB);
}
int main(int argc,char **argv){
    if(argc!=2)return 2;load_bin(argv[1]);if(g_nadd!=10 || g_nconv!=72)return 2;
    g_adds=realloc(g_adds,15*sizeof(*g_adds));if(!g_adds)return 2;
    const i32 params[5][4]={{1,2,3,3},{1,1,1,1},{3,0,3,0},{0,63,0,63},{2147483647,0,2147483647,0}};
    for(int i=0;i<5;i++){
        AddRec *r=&g_adds[g_nadd++];memset(r,0,sizeof(*r));snprintf(r->name,48,"add.custom.%d",i);r->bits=16;
        r->multA=params[i][0];r->shiftA=params[i][1];r->multB=params[i][2];r->shiftB=params[i][3];
    }
    unit_file=open_file("unit.mem","w");
    // 可手算锚点，防止两路舍入顺序或中途INT16饱和被误写。
    emit_unit(1,1,1,1,1,1,2,0);emit_unit(-1,-1,1,1,1,1,0,0);
    emit_unit(20000,-10000,3,0,3,0,30000,0);emit_unit(32767,32767,1,0,1,0,32767,0);
    emit_unit(-32768,-32768,1,0,1,0,-32767,0);
    for(int r=0;r<15;r++){
        Tensor a=t_alloc(1,1,64),b=t_alloc(1,1,64);
        for(int k=0;k<64;k++){a.d[k]=(i16)((int)(random_word()%65536)-32768);b.d[k]=(i16)((int)(random_word()%65536)-32768);}
        a.d[0]=1;b.d[0]=1;a.d[1]=-1;b.d[1]=-1;a.d[2]=-32768;b.d[2]=32767;
        Tensor y=add_point(&a,&b,g_adds[r].name);
        for(int k=0;k<64;k++)emit_unit(a.d[k],b.d[k],g_adds[r].multA,g_adds[r].shiftA,g_adds[r].multB,g_adds[r].shiftB,y.d[k],0);
    }
    emit_unit(1,1,0x80000000u,0,1,0,0,1);emit_unit(1,1,1,64,1,0,0,1);
    emit_unit(1,1,1,0,0x80000000u,0,0,1);emit_unit(1,1,1,0,1,64,0,1);fclose(unit_file);
    initial_file=open_file("ddr/initial.mem","w");golden_file=open_file("ddr/golden.mem","w");job_file=open_file("ddr/jobs.mem","w");
    for(int i=0;i<15;i++)create_direct(i,&g_adds[i]);fclose(initial_file);fclose(golden_file);fclose(job_file);
    FILE *counts=open_file("add_counts.json","w");fprintf(counts,"{\"unit_vectors\":%u,\"layers\":15,\"initial\":%u,\"golden\":%u}\n",unit_count,initial_count,golden_count);fclose(counts);
    g_convs=realloc(g_convs,75*sizeof(*g_convs));if(!g_convs)return 2;
    add_custom(17,17,1,1,0,16,0,1);add_custom(17,17,3,1,1,0,1,1);add_custom(17,3,1,1,0,0,0,0);
    for(int net=0;net<3;net++){
        Tensor input=t_alloc(net==0 ? 64:17,1,3),out[5];char path[80];
        for(int i=0;i<input.c*input.h*input.w;i++)input.d[i]=(i16)((int)(random_word()%2047)-1023);
        snprintf(path,80,"network%d.input.bin",net);write_tensor(path,&input,0);
        char json_name[80];snprintf(json_name,80,"network%d.json",net);FILE *f=open_file(json_name,"w");
        fprintf(f,"{\"activation_bits\":16,\"input\":{\"shape\":[1,3,%d],\"data_file\":\"%s\"},\"layers\":[\n",input.c,path);
        int n=net==0 ? 3:net==1 ? 5:2;
        for(int l=0;l<n;l++){
            if((net==0 && l==2) || (net==1 && (l==2 || l==4)) || net==2){
                int a=-1,b=l-1;AddRec *r=net==0 ? find_add("model.2.m.0.add"):find_add(net==1 ? "add.custom.0":"add.custom.1");
                if(net==1 && l==4){a=0;b=2;}
                out[l]=add_point(a<0 ? &input:&out[a],b<0 ? &input:&out[b],r->name);write_add(f,l,a,b,r);
            }else{
                const char *name=net==0 ? (l==0 ? "model.2.m.0.cv1":"model.2.m.0.cv2"):
                    (l==0 ? "task.custom.0":l==1 ? "task.custom.1":"task.custom.2");
                const ConvRec *r=find_conv(name);out[l]=conv_layer(l==0 ? &input:&out[l-1],name);
                write_layer(f,net,l,r,l-1,!(net==1 && l==3));
            }
            snprintf(path,80,"network%d.layer%d.expected.bin",net,l);write_tensor(path,&out[l],1);
        }
        fputs("\n]}\n",f);fclose(f);
    }
    return 0;
}
