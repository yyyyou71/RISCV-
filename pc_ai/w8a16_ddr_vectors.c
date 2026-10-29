/* 原 C 卷积 → 完整 HWC DDR 输入/权重/偏置/量化表/期望输出。
 * 不修改参考工程，不重新实现 Python 数学模型。
 */
#ifndef TRIDENT_SOURCE
#error "需要指定参考 rearch_fixed.c"
#endif
#define main trident_original_main
#include TRIDENT_SOURCE
#undef main

static FILE *fi,*fg,*fj;
static u32 ni,ng,nj,seed=0x16882026u;
static u32 random_word(void){seed=seed*1664525u+1013904223u;return seed;}
static void words(FILE *f,const u32 *w,int n){for(int i=n-1;i>=0;i--)fprintf(f,"%08x",w[i]);fputc('\n',f);}
static void initial_word(u32 addr,const u8 *data){
    fprintf(fi,"%08x",addr);for(int i=15;i>=0;i--)fprintf(fi,"%02x",data[i]);fputc('\n',fi);ni++;
}
static void put32(u8 *p,u32 v){for(int i=0;i<4;i++)p[i]=(u8)(v>>(8*i));}
static void initial_u32(u32 addr,const u32 *v,int n){
    for(int j=0;j<n;j+=4){u8 b[16]={0};for(int k=0;k<4 && j+k<n;k++)put32(b+k*4,v[j+k]);initial_word(addr+j*4,b);}
}
static void emit_layer(const ConvRec *r,const Tensor *x,const Tensor *y,u32 ia,u32 wa,u32 ba,u32 qa,u32 oa,int preload_input,int cpu,u32 *desc){
    u32 ci=(r->C+15)&~15,co=(r->O+3)&~3,op=(r->O+15)&~15;
    u32 start=ni,gstart=ng;
    if(preload_input)for(int p=0;p<x->h*x->w;p++)for(u32 c=0;c<ci;c+=8){
        u8 b[16];for(int j=0;j<8;j++){uint16_t v=c+j<(u32)x->c ? (uint16_t)x->d[(size_t)(c+j)*x->h*x->w+p]:0x5555u;b[j*2]=v;b[j*2+1]=v>>8;}
        initial_word(ia+(p*ci+c)*2,b);
    }
    for(u32 o=0;o<co;o++)for(int t=0;t<r->kh*r->kw;t++)for(u32 c=0;c<ci;c+=16){
        u8 b[16];for(int j=0;j<16;j++)b[j]=o<(u32)r->O && c+j<(u32)r->C ?
            (u8)r->w[((size_t)o*r->C+c+j)*r->kh*r->kw+t]:0x66;
        initial_word(wa+(o*r->kh*r->kw+t)*ci+c,b);
    }
    for(u32 o=0;o<co;o+=4){u32 b[4];for(int l=0;l<4;l++)b[l]=o+l<(u32)r->O ? (u32)r->bias_q13[o+l]:0x23456789u;initial_u32(ba+o*4,b,4);}
    for(u32 o=0;o<co;o++){
        u32 q[8]={0};if(o<(u32)r->O){q[0]=r->multM[o];q[1]=r->shiftM[0];
            if(r->n_groups==2){q[2]=r->multM[r->O+o];q[3]=r->shiftM[1];}q[4]=r->multY;q[5]=r->shiftY;}
        initial_u32(qa+o*32,q,8);
    }
    u32 size=y->h*y->w*op*2;
    u8 guard[16];memset(guard,0xa5,16);initial_word(oa-16,guard);memset(guard,0x5a,16);initial_word(oa+size,guard);
    for(int p=0;p<y->h*y->w;p++)for(u32 c=0;c<op;c+=8){
        u8 b[16];for(int j=0;j<8;j++){uint16_t v=c+j<(u32)y->c ? (uint16_t)y->d[(size_t)(c+j)*y->h*y->w+p]:0;b[j*2]=v;b[j*2+1]=v>>8;}
        for(int j=15;j>=0;j--)fprintf(fg,"%02x",b[j]);fputc('\n',fg);ng++;
        if(cpu){initial_word(0x10000000u+(ng-1)*16,b);memset(b,0xa7,16);initial_word(oa+(p*op+c)*2,b);}
    }
    u32 job[15]={0};job[0]=(u32)x->h|((u32)x->w<<16);job[1]=(u32)r->C|((u32)r->O<<16);
    job[2]=(u32)r->kh|((u32)r->sh<<2)|((u32)r->pad<<4)|(1u<<6);
    job[3]=ia;job[4]=wa;job[5]=ba;job[6]=oa;job[7]=start;job[8]=ni-start;
    // 补充无偏置配置：地址故意无效，RTL不得读取或校验未启用的偏置区域。
    if(!cpu && strcmp(r->name,"ddr.case.10")==0){job[2]&=~(1u<<6);job[5]=0xdeadbeefu;}
    job[9]=gstart;job[10]=size/16;job[11]=(u32)y->h*y->w*((r->O+3)/4)*((r->C+15)/16)*r->kh*r->kw*8;
    job[12]=qa;job[13]=4u|((u32)r->act<<1);job[14]=r->n_groups==2 ? r->ch1[0]:0;
    words(fj,job,15);nj++;
    if(cpu){
        desc[0]=ia;desc[1]=wa;desc[2]=ba;desc[3]=oa;desc[4]=job[0];desc[5]=job[1];desc[6]=job[2];
        desc[7]=job[13];desc[8]=qa;desc[9]=job[14];desc[10]=size;desc[11]=0x10000000u+gstart*16;
        desc[12]=job[11];desc[13]=y->h;desc[14]=y->w;desc[15]=0;
    }
}
int main(int argc,char **argv){
    if(argc!=3){fprintf(stderr,"usage: vectors weights.bin engine|cpu|cpu_groups\n");return 2;}
    load_bin(argv[1]);int cpu=strncmp(argv[2],"cpu",3)==0;
    fi=fopen("initial.mem","w");fg=fopen("golden.mem","w");fj=fopen("jobs.mem","w");if(!fi || !fg || !fj)return 2;
    if(cpu){
        const char *second="model.1";
        if(strcmp(argv[2],"cpu_groups")==0){
            // 仅用于检验非零AI_GROUP跨域和两尺度量化，不宣称是原网络的等价替换。
            ConvRec r=*find_conv("model.1");r.n_groups=2;r.ch0[0]=0;r.ch1[0]=16;r.ch0[1]=16;r.ch1[1]=32;
            r.shiftM[1]=r.shiftM[0]+1;i32 *m=malloc((size_t)r.O*2*4);
            for(int o=0;o<r.O;o++)m[o]=m[r.O+o]=r.multM[o];r.multM=m;strcpy(r.name,"cpu.grouped");
            g_convs=realloc(g_convs,(g_nconv+1)*sizeof(*g_convs));if(!g_convs)return 2;
            g_convs[g_nconv++]=r;second="cpu.grouped";
        }
        Tensor x=t_alloc(3,5,7);for(int i=0;i<x.c*x.h*x.w;i++)x.d[i]=random_word()&255;
        Tensor a=conv_layer(&x,"model.0"),b=conv_layer(&a,second);u32 d[32];
        emit_layer(find_conv("model.0"),&x,&a,0x7f0,0x1fff0,0x40000,0x50000,0x807f0,1,1,d);
        emit_layer(find_conv(second),&a,&b,0x807f0,0x60000,0x68000,0x69000,0x90000,0,1,d+16);
        initial_u32(0x1000,d,32);
    }else{
        const char *names[]={"model.0","model.1","model.2.cv3","model.4.cv3","model.13.cv1","model.16.cv1","model.7","model.23.one2one_cv2.0.2"};
        int outputs[]={5,17,19,33,5,1,5,3};
        int original_count=g_nconv;g_convs=realloc(g_convs,(original_count+12)*sizeof(*g_convs));if(!g_convs)return 2;
        for(int j=0;j<12;j++){
            ConvRec *r=&g_convs[original_count+j];
            if(j<8){
                ConvRec source=*find_conv(names[j]);*r=source;r->O=outputs[j];
                r->multM=malloc((size_t)r->n_groups*r->O*sizeof(i32));
                for(int g=0;g<r->n_groups;g++)for(int o=0;o<r->O;o++)r->multM[g*r->O+o]=source.multM[g*source.O+o];
            }else{
                memset(r,0,sizeof(*r));r->C=j==8 ? 17:j==9 ? 33:3;r->O=j==8 ? 9:j==9 ? 17:1;
                r->kh=r->kw=j==8 ? 3:1;r->sh=r->sw=j==8 ? 2:1;r->pad=j==8 ? 1:0;r->act=j%2;
                r->n_groups=j==8 || j==9 ? 2:1;r->ch1[0]=r->n_groups==2 ? 16:r->C;r->ch0[1]=16;r->ch1[1]=r->C;
                r->shiftM[0]=1;r->shiftM[1]=2;r->multY=1;r->shiftY=0;r->out_bits=16;
                r->multM=malloc((size_t)r->n_groups*r->O*4);r->bias_q13=malloc(r->O*4);r->w=malloc((size_t)r->O*r->C*r->kh*r->kw);
                for(int g=0;g<r->n_groups;g++)for(int o=0;o<r->O;o++)r->multM[g*r->O+o]=j==10 ? 0:g ? 3:1;
                for(int o=0;o<r->O;o++)r->bias_q13[o]=j==10 ? 0:o-5;
                for(int k=0;k<r->O*r->C*r->kh*r->kw;k++)r->w[k]=(int8_t)((int)(random_word()%15)-7);
            }
            snprintf(r->name,48,"ddr.case.%d",j);g_nconv=original_count+j+1;
            Tensor x=t_alloc(r->C,j==0 || j==8 ? 3:1,j==0 ? 5:3);
            for(int k=0;k<x.c*x.h*x.w;k++)x.d[k]=j<2 ? random_word()&255:(i16)((int)(random_word()%2047)-1023);
            Tensor y=conv_layer(&x,r->name);
            emit_layer(r,&x,&y,0x7f0,0x1fff0,0x40000,0x50000,0x807f0,1,0,NULL);
        }
    }
    fclose(fi);fclose(fg);fclose(fj);FILE *f=fopen("counts.json","w");if(!f)return 2;
    fprintf(f,"{\"layers\":%u,\"initial_words\":%u,\"golden_words\":%u,\"connected\":%s}\n",nj,ni,ng,cpu ? "true":"false");fclose(f);return 0;
}
