/* 用参考工程的 conv_layer 生成 RTL 期望值；只做独立卷积，不运行完整检测网络。
 * 输入/权重打包不执行 Python 数学参考，材料目录保持只读。
 */
#ifndef TRIDENT_SOURCE
#error "需要指定参考 rearch_fixed.c"
#endif
#define main trident_original_main
#include TRIDENT_SOURCE
#undef main
#include <limits.h>

static FILE *fj, *fx, *fw, *fn, *fq;
static unsigned ncase, nword, nquant;
static u32 seed=0x20261026u;
static u32 next_rand(void) { seed=seed*1664525u+1013904223u; return seed; }

static void write_words(FILE *f,const u32 *v,int n) {
    for(int i=n-1;i>=0;i--) fprintf(f,"%08x",v[i]);
    fputc('\n',f);
}

static void emit_case(const ConvRec *r,const Tensor *x,const Tensor *y,int oy,int ox,int base) {
    u32 job[26]={0};
    int blocks[2]={0,0};
    i64 acc[2][4]={{0}};
    for(int g=0;g<r->n_groups;g++) blocks[g]=(r->ch1[g]-r->ch0[g]+15)/16;
    job[0]=r->kh*r->kw;
    job[1]=(u32)blocks[0]|((u32)blocks[1]<<16);
    job[2]=(u32)r->act<<4;
    job[3]=r->shiftM[0]; job[4]=r->n_groups>1 ? r->shiftM[1]:0; job[5]=r->shiftY;
    job[25]=nword;
    for(int l=0;l<4;l++) if(base+l<r->O) {
        job[2]|=1u<<l;
        job[6+l]=r->multM[base+l];
        job[10+l]=r->n_groups>1 ? r->multM[r->O+base+l]:0;
        job[14+l]=r->bias_q13[base+l]; job[18+l]=r->multY;
        job[22+l/2]|=(u32)(uint16_t)t_at(y,base+l,oy,ox)<<((l%2)*16);
    }
    for(int g=0;g<r->n_groups;g++) for(int b=0;b<blocks[g];b++)
        for(int ky=0;ky<r->kh;ky++) for(int kx=0;kx<r->kw;kx++) {
            i16 xv[16]={0}; int8_t wv[4][16]={{0}};
            int iy=oy*r->sh+ky-r->pad, ix=ox*r->sw+kx-r->pad;
            for(int c=0;c<16;c++) {
                unsigned ci=r->ch0[g]+b*16+c;
                if(ci>=r->ch1[g]) continue;
                if(iy>=0 && iy<x->h && ix>=0 && ix<x->w) xv[c]=t_at(x,ci,iy,ix);
                for(int l=0;l<4;l++) if(base+l<r->O) {
                    wv[l][c]=r->w[(((size_t)(base+l)*r->C+ci)*r->kh+ky)*r->kw+kx];
                    acc[g][l]+=(i64)xv[c]*wv[l][c];
                }
            }
            for(int c=15;c>=0;c--) fprintf(fx,"%04x",(unsigned)(uint16_t)xv[c]);
            fputc('\n',fx);
            for(int l=0;l<4;l++) {
                for(int c=15;c>=0;c--) fprintf(fw,"%02x",(unsigned)(uint8_t)wv[l][c]);
                fputc('\n',fw);
            }
            nword++;
        }
    for(int l=0;l<4;l++) if(base+l<r->O) {
        i64 v=r->bias_q13[base+l];
        for(int g=0;g<r->n_groups;g++) v+=shr(acc[g][l]*r->multM[g*r->O+base+l],r->shiftM[g]);
        if(v>INT32_MAX || v<INT32_MIN) job[24]|=1u<<l;
    }
    write_words(fj,job,26);
    fprintf(fn,"%s{\"index\":%u,\"layer\":\"%s\",\"y\":%d,\"x\":%d,\"channel_base\":%d}",
        ncase ? ",\n":"",ncase,r->name,oy,ox,base);
    ncase++;
}

static __int128 round128(__int128 a,u32 sh) {
    return sh ? (a+((__int128)1<<(sh-1)))>>sh : a;
}
static void emit_quant(i64 a,i64 b,int g,u32 m0,u32 s0,u32 m1,u32 s1,i32 bias,u32 my,u32 sy,int relu) {
    u32 v[14]={0};
    v[0]=(u32)a; v[1]=(u32)((uint64_t)a>>32); v[2]=(u32)b; v[3]=(u32)((uint64_t)b>>32);
    v[4]=g; v[5]=m0; v[6]=s0; v[7]=m1; v[8]=s1; v[9]=(u32)bias;
    v[10]=my; v[11]=sy; v[12]=relu;
    int bad=m0>INT32_MAX || my>INT32_MAX || s0>95 || sy>95 || (g && (m1>INT32_MAX || s1>95));
    if(bad) v[13]=1u<<16;
    else {
        __int128 q=round128((__int128)a*m0,s0)+(g ? round128((__int128)b*m1,s1):0)+bias;
        int clamped=q>INT32_MAX || q<INT32_MIN;
        if(q>INT32_MAX) q=INT32_MAX;
        if(q<INT32_MIN) q=INT32_MIN;
        if(relu && q<0) q=0;
        q=round128(q*my,sy);
        if(q>32767) q=32767;
        if(q< -32767) q= -32767;
        v[13]=(u32)(uint16_t)(i16)q|((u32)clamped<<17);
    }
    write_words(fq,v,14); nquant++;
}

int main(int argc,char **argv) {
    if(argc!=2) { fprintf(stderr,"usage: vectors weights.bin\n"); return 2; }
    load_bin(argv[1]);
    if(g_nconv!=72) return 2;
    fj=fopen("jobs.mem","w"); fx=fopen("inputs.mem","w"); fw=fopen("weights.mem","w");
    fn=fopen("cases.json","w"); fq=fopen("quant.mem","w");
    if(!fj || !fx || !fw || !fn || !fq) { perror("vectors"); return 2; }
    fputs("[\n",fn);
    int real_convs=g_nconv;
    g_convs=realloc(g_convs,(real_convs+12)*sizeof(*g_convs));
    if(!g_convs) return 2;
    for(int i=0;i<real_convs+12;i++) {
        ConvRec *r=&g_convs[i];
        if(i>=real_convs) {
            int ci_list[12]={1,3,15,16,17,31,33,33,17,3,1,1};
            int j=i-real_convs;
            memset(r,0,sizeof(*r)); snprintf(r->name,sizeof(r->name),"rtl.directed.%d",j);
            r->C=ci_list[j]; r->O=j%3==0 ? 3:5;
            r->kh=r->kw=j%2 ? 3:1; r->sh=r->sw=j%3==1 ? 2:1;
            r->pad=r->kh==3 ? 1:0; r->act=j%2; r->out_bits=16;
            r->n_groups=(j>=4 && j<=8) ? 2:1;
            r->ch0[0]=0; r->ch1[0]=r->n_groups==2 ? 16:r->C;
            r->ch0[1]=16; r->ch1[1]=r->C;
            // 原 C 的 shr 使用 int64，卷积向量限制在 0..63；95 位边界由下面 __int128 量化向量覆盖。
            r->shiftM[0]=j==10 ? 63:j==9 ? 0:1; r->shiftM[1]=2;
            r->multY=j==9 ? INT32_MAX:1; r->shiftY=j==10 ? 63:0;
            r->multM=calloc((size_t)r->n_groups*r->O,sizeof(i32));
            r->bias_q13=calloc(r->O,sizeof(i32)); r->w=malloc((size_t)r->O*r->C*r->kh*r->kw);
            for(int g=0;g<r->n_groups;g++) for(int o=0;o<r->O;o++) r->multM[g*r->O+o]=j==9 ? INT32_MAX:(g ? 5:1);
            for(int o=0;o<r->O;o++) r->bias_q13[o]=j==9 ? (o%2 ? INT32_MIN:INT32_MAX):(o-2)*7;
            for(int k=0;k<r->O*r->C*r->kh*r->kw;k++) r->w[k]=j>=9 ? 1:(int8_t)(next_rand()>>24);
            g_nconv=i+1;
        }
        Tensor x=t_alloc(r->C,5,7);
        for(int k=0;k<x.c*x.h*x.w;k++) {
            x.d[k]=i==0 ? (i16)(next_rand()&255):(i16)((int)(next_rand()%65535)-32767);
            if(i==real_convs+9) x.d[k]=32767;
            if(i==real_convs+11) x.d[k]=-1;
        }
        Tensor y=conv_layer(&x,r->name);
        emit_case(r,&x,&y,0,0,0);
        emit_case(r,&x,&y,y.h-1,y.w-1,(r->O-1)&~3);
        emit_case(r,&x,&y,y.h/2,y.w/2,0);
        t_free(&x);
    }
    fputs("\n]\n",fn);
    i64 values[]={INT64_MIN,INT64_MIN+1,-2147483649LL,-32767,-5,-3,-1,0,1,3,5,32767,INT64_MAX};
    u32 multipliers[]={0,1,3,INT32_MAX}, shifts[]={0,1,31,63,94,95};
    for(unsigned a=0;a<sizeof(values)/sizeof(*values);a++)
        for(unsigned m=0;m<4;m++) for(unsigned s=0;s<6;s++) for(int relu=0;relu<2;relu++)
            emit_quant(values[a],values[(a+3)%13],a%2,multipliers[m],shifts[s],3,1,
                a%3==0 ? INT32_MIN:a%3==1 ? INT32_MAX:0,multipliers[(m+1)%4],shifts[(s+2)%6],relu);
    // 独立的可手算锚点：+1/2→1，-1/2→0；两组必须先分别舍入再相加。
    emit_quant(1,0,0,1,1,0,0,0,1,0,0);
    emit_quant(-1,0,0,1,1,0,0,0,1,0,0);
    emit_quant(1,1,1,1,1,1,1,0,1,0,0);
    emit_quant(3,0,0,1,0,0xffffffffu,0xffffffffu,0,1,0,0);
    emit_quant(1,1,0,0x80000000u,0,1,0,0,1,0,0);
    emit_quant(1,1,0,1,96,1,0,0,1,0,0);
    emit_quant(1,1,1,1,0,0x80000000u,0,0,1,0,0);
    emit_quant(1,1,1,1,0,1,96,0,1,0,0);
    emit_quant(1,1,0,1,0,1,0,0,0x80000000u,0,0);
    emit_quant(1,1,0,1,0,1,0,0,1,96,0);
    fclose(fj); fclose(fx); fclose(fw); fclose(fn); fclose(fq);
    FILE *f=fopen("counts.json","w"); if(!f) return 2;
    fprintf(f,"{\"cases\":%u,\"input_words\":%u,\"weight_words\":%u,\"quant_vectors\":%u,\"real_convolution_records\":%d,\"directed_convolutions\":12}\n",
        ncase,nword,nword*4,nquant,real_convs); fclose(f);
    return 0;
}
