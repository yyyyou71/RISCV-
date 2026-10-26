/* 导出整数网络JSON/资产和逐层C期望值。只运行卷积片段，不运行完整检测网络。 */
#ifndef TRIDENT_SOURCE
#error "需要参考rearch_fixed.c"
#endif
#define main trident_original_main
#include TRIDENT_SOURCE
#undef main

static u32 rng_state=0x16162026u;
static u32 random_word(void){rng_state=rng_state*1664525u+1013904223u;return rng_state;}
static void little16(FILE *f,i16 v){u32 q=(uint16_t)v;fputc(q&255,f);fputc((q>>8)&255,f);}
static void little32(FILE *f,i32 v){u32 q=(u32)v;for(int i=0;i<4;i++)fputc((q>>(i*8))&255,f);}
static FILE *open_file(const char *name,const char *mode){FILE *f=fopen(name,mode);if(!f){perror(name);exit(2);}return f;}

static void write_tensor(const char *name,const Tensor *x,int padded){
    FILE *f=open_file(name,"wb");int channels=padded ? (x->c+15)&~15:x->c;
    for(int y=0;y<x->h;y++)for(int w=0;w<x->w;w++)for(int c=0;c<channels;c++)
        little16(f,c<x->c ? t_at(x,c,y,w):0);
    fclose(f);
}
static void write_layer(FILE *spec,int net,int layer,const ConvRec *r,int source,int bias_enable){
    char wname[80],bname[80];
    snprintf(wname,sizeof(wname),"network%d.layer%d.weights.bin",net,layer);
    snprintf(bname,sizeof(bname),"network%d.layer%d.bias.bin",net,layer);
    FILE *f=open_file(wname,"wb");
    for(int o=0;o<r->O;o++)for(int ky=0;ky<r->kh;ky++)for(int kx=0;kx<r->kw;kx++)for(int c=0;c<r->C;c++)
        fputc((u8)r->w[(((size_t)o*r->C+c)*r->kh+ky)*r->kw+kx],f);
    fclose(f);
    f=open_file(bname,"wb");for(int o=0;o<r->O;o++)little32(f,r->bias_q13[o]);fclose(f);
    fprintf(spec,"%s{\"name\":\"layer%d\",\"input\":\"",layer ? ",\n":"",layer);
    if(source<0)fputs("input",spec);else fprintf(spec,"layer%d",source);
    fprintf(spec,"\",\"op\":\"conv2d\",\"out_channels\":%d,\"kernel\":%d,\"stride\":%d,\"padding\":%d,\"relu\":%s,\"bias_enable\":%s,\"weights_file\":\"%s\",",
        r->O,r->kh,r->sh,r->pad,r->act ? "true":"false",bias_enable ? "true":"false",wname);
    if(bias_enable)fprintf(spec,"\"biases_file\":\"%s\",",bname);
    fprintf(spec,"\"group_split\":%u,\"quant_q13\":[",r->n_groups==2 ? r->ch1[0]:0);
    for(int o=0;o<r->O;o++)fprintf(spec,"%s[%d,%d,%d,%d,%d,%d]",o ? ",":"",r->multM[o],r->shiftM[0],
        r->n_groups==2 ? r->multM[r->O+o]:0,r->n_groups==2 ? r->shiftM[1]:0,r->multY,r->shiftY);
    fputs("]}",spec);
}
static void add_custom(int ci,int co,int kernel,int stride,int padding,int split,int act,int bias_enable){
    ConvRec *r=&g_convs[g_nconv];memset(r,0,sizeof(*r));snprintf(r->name,48,"task.custom.%d",g_nconv-72);
    r->C=ci;r->O=co;r->kh=r->kw=kernel;r->sh=r->sw=stride;r->pad=padding;r->act=act;r->out_bits=16;
    r->n_groups=split ? 2:1;r->ch1[0]=split ? split:ci;r->ch0[1]=split;r->ch1[1]=ci;
    r->shiftM[0]=3;r->shiftM[1]=4;r->multY=1;r->shiftY=0;
    r->multM=malloc((size_t)r->n_groups*co*4);r->bias_q13=malloc(co*4);r->w=malloc((size_t)co*ci*kernel*kernel);
    for(int g=0;g<r->n_groups;g++)for(int o=0;o<co;o++)r->multM[g*co+o]=g ? 3:1;
    for(int o=0;o<co;o++)r->bias_q13[o]=bias_enable ? o-7:0;
    for(int i=0;i<co*ci*kernel*kernel;i++)r->w[i]=(int8_t)((int)(random_word()%7)-3);
    g_nconv++;
}
int main(int argc,char **argv){
    if(argc!=2){fprintf(stderr,"usage: export weights.bin\n");return 2;}
    load_bin(argv[1]);if(g_nconv!=72)return 2;
    g_convs=realloc(g_convs,75*sizeof(*g_convs));if(!g_convs)return 2;
    add_custom(17,17,1,1,0,16,0,1);
    add_custom(17,5,3,1,1,16,1,1);
    add_custom(17,3,1,2,0,0,0,0);
    const char *names[3][3]={{"model.0","model.1",NULL},{"model.0","model.1","model.2.cv1"},
                           {"task.custom.0","task.custom.1","task.custom.2"}};
    for(int net=0;net<3;net++){
        Tensor input=t_alloc(net==2 ? 17:3,net==0 ? 5:net==1 ? 3:1,net==0 ? 7:net==1 ? 5:3);
        for(int k=0;k<input.c*input.h*input.w;k++)input.d[k]=net==2 ? (i16)((int)(random_word()%201)-100):(i16)(random_word()&255);
        char path[80];snprintf(path,sizeof(path),"network%d.input.bin",net);write_tensor(path,&input,0);
        char json_name[80];snprintf(json_name,sizeof(json_name),"network%d.json",net);FILE *spec=open_file(json_name,"w");
        fprintf(spec,"{\"activation_bits\":16,\"input\":{\"shape\":[%d,%d,%d],\"data_file\":\"%s\"},\"layers\":[\n",
            input.h,input.w,input.c,path);
        Tensor outputs[3];int count=net==0 ? 2:3;
        for(int layer=0;layer<count;layer++){
            int source=layer-1;if(net==2 && layer==2)source=0;
            const ConvRec *r=find_conv(names[net][layer]);const Tensor *x=source<0 ? &input:&outputs[source];
            outputs[layer]=conv_layer(x,r->name);
            write_layer(spec,net,layer,r,source,!(net==2 && layer==2));
            snprintf(path,sizeof(path),"network%d.layer%d.expected.bin",net,layer);write_tensor(path,&outputs[layer],1);
        }
        fputs("\n]}\n",spec);fclose(spec);
    }
    return 0;
}
