/* 从原整数资产导出完整计算图；默认只布局，显式指定limit才计算C期望值。
 * 数值计算直接调用原C的五类算子，不修改materials目录。
 */
#define W8A16_EXPORT_LIBRARY
#include "export_w8a16_tasks.c"

enum { N_CONV=1,N_ADD=2,N_CAT=3,N_POOL=4,N_UP=5 };
typedef struct { int h,w,c; } Shape;
typedef struct { int op,a,b;char name[80];Shape shape; } Node;
static Node nodes[99];static int node_count;
static Shape input_shape;
static int head_box[3],head_cls[3];
static const char *op_names[]={"","conv2d","add","concat","maxpool5","upsample2x"};

static void require(int condition,const char *message){if(!condition){fprintf(stderr,"graph: %s\n",message);exit(2);}}
static Shape shape_at(int source){require(source>=-1 && source<node_count,"source order");return source<0 ? input_shape:nodes[source].shape;}
static int node(int op,int a,int b,const char *name){
    require(node_count<99,"too many nodes");Shape x=shape_at(a),s=x;
    if(op==N_CONV){
        ConvRec *r=find_conv(name);require(r->C==x.c && r->kh==r->kw && r->sh==r->sw,"conv shape");
        require((r->kind==0 || r->kind==2) && r->out_bits==16 && (r->n_groups==1 || r->n_groups==2),"conv format");
        require(r->ch0[0]==0 && r->ch1[r->n_groups-1]==(u32)x.c,"group coverage");
        if(r->n_groups==2)require(r->ch1[0]==r->ch0[1] && r->ch1[0]%16==0,"group boundary");
        s=(Shape){(x.h+2*r->pad-r->kh)/r->sh+1,(x.w+2*r->pad-r->kw)/r->sw+1,r->O};
    }else if(op==N_ADD || op==N_CAT){
        Shape y=shape_at(b);require(x.h==y.h && x.w==y.w,"binary spatial shape");
        if(op==N_ADD){require(x.c==y.c && find_add(name)->bits==16,"add shape/format");}
        else s.c=x.c+y.c;
    }else if(op==N_UP){s.h*=2;s.w*=2;}
    require(s.h>0 && s.w>0 && s.c>0 && s.h<=65535 && s.w<=65535 && s.c<=65535,"output dimensions");
    for(int i=0;i<node_count;i++)require(strcmp(nodes[i].name,name)!=0,"duplicate name");
    Node *n=&nodes[node_count];n->op=op;n->a=a;n->b=b;n->shape=s;snprintf(n->name,sizeof(n->name),"%s",name);
    return node_count++;
}
static int conv(int source,const char *name){return node(N_CONV,source,-1,name);}
static int c3(int source,int module){
    char nm[80];snprintf(nm,80,"model.%d.cv1",module);int a=conv(source,nm);
    snprintf(nm,80,"model.%d.m.0.cv1",module);int b=conv(a,nm);
    snprintf(nm,80,"model.%d.m.0.cv2",module);b=conv(b,nm);
    snprintf(nm,80,"model.%d.m.0.add",module);int z=node(N_ADD,a,b,nm);
    snprintf(nm,80,"model.%d.cv2",module);b=conv(source,nm);
    snprintf(nm,80,"model.%d.concat",module);z=node(N_CAT,z,b,nm);
    snprintf(nm,80,"model.%d.cv3",module);return conv(z,nm);
}
static int sppf(int source){
    int a=conv(source,"model.9.cv1"),b=node(N_POOL,a,-1,"model.9.pool");
    b=node(N_CAT,a,b,"model.9.concat");b=conv(b,"model.9.cv2");
    return node(N_ADD,source,b,"model.9.add");
}
static void build_graph(void){
    int x=conv(-1,"model.0");x=conv(x,"model.1");x=c3(x,2);x=conv(x,"model.3");
    int x4=c3(x,4);x=conv(x4,"model.5");int x6=c3(x,6);x=conv(x6,"model.7");
    x=c3(x,8);x=sppf(x);int x10=c3(x,10);
    x=node(N_UP,x10,-1,"model.11.up");x=node(N_CAT,x,x6,"model.12.concat");int x13=c3(x,13);
    x=node(N_UP,x13,-1,"model.14.up");x=node(N_CAT,x,x4,"model.15.concat");int x16=c3(x,16);
    x=conv(x16,"model.17");x=node(N_CAT,x,x13,"model.18.concat");int x19=c3(x,19);
    x=conv(x19,"model.20");x=node(N_CAT,x,x10,"model.21.concat");int x22=c3(x,22);
    const int features[3]={x16,x19,x22};char nm[80];
    for(int i=0;i<3;i++){
        for(int branch=0;branch<2;branch++){
            x=features[i];for(int j=0;j<3;j++){
                snprintf(nm,80,"model.23.one2one_cv%d.%d.%d",branch ? 3:2,i,j);x=conv(x,nm);
            }
            if(branch)head_cls[i]=x;else head_box[i]=x;
        }
    }
    int counts[6]={0};for(int i=0;i<node_count;i++)counts[nodes[i].op]++;
    require(node_count==99 && counts[1]==72 && counts[2]==10 && counts[3]==14 && counts[4]==1 && counts[5]==2,"operator counts");
    for(int i=0;i<g_nconv;i++){
        int seen=0;for(int j=0;j<node_count;j++)seen+=nodes[j].op==N_CONV && strcmp(nodes[j].name,g_convs[i].name)==0;
        require(seen==1,"conv record usage");
    }
    for(int i=0;i<g_nadd;i++){
        int seen=0;for(int j=0;j<node_count;j++)seen+=nodes[j].op==N_ADD && strcmp(nodes[j].name,g_adds[i].name)==0;
        require(seen==1,"add record usage");
    }
    for(int i=0;i<3;i++){
        Shape b=nodes[head_box[i]].shape,c=nodes[head_cls[i]].shape;
        require(b.c==4 && c.c==80 && b.h==input_shape.h/(8<<i) && b.w==input_shape.w/(8<<i),"head shape");
        require(c.h==b.h && c.w==b.w && g_sig[i].head==(u32)i,"head order");
        require(strcmp(g_sig[i].box_point,nodes[head_box[i]].name)==0 && strcmp(g_sig[i].cls_point,nodes[head_cls[i]].name)==0,"head point");
    }
}
static void source_name(FILE *f,int source){if(source<0)fputs("input",f);else fprintf(f,"layer%d",source);}
static void export_spec(const Tensor *input){
    write_tensor("network0.input.bin",input,0);
    FILE *f=open_file("network0.json","w");
    fprintf(f,"{\"activation_bits\":16,\"input\":{\"shape\":[%d,%d,3],\"data_file\":\"network0.input.bin\"},\"layers\":[\n",input->h,input->w);
    for(int i=0;i<node_count;i++){
        Node *n=&nodes[i];
        if(n->op==N_CONV){write_layer(f,0,i,find_conv(n->name),n->a,1);continue;}
        fprintf(f,"%s{\"name\":\"layer%d\",\"op\":\"%s\",\"input\":\"",i ? ",\n":"",i,op_names[n->op]);source_name(f,n->a);fputc('"',f);
        if(n->op==N_ADD || n->op==N_CAT){fputs(",\"input_b\":\"",f);source_name(f,n->b);fputc('"',f);}
        if(n->op==N_ADD){AddRec *r=find_add(n->name);fprintf(f,",\"quant_add\":[%d,%d,%d,%d]",r->multA,r->shiftA,r->multB,r->shiftB);}
        fputc('}',f);
    }
    fputs("\n]}\n",f);fclose(f);
    f=open_file("graph.json","w");fprintf(f,"{\"schema\":1,\"input_shape\":[%d,%d,3],\"nodes\":[\n",input->h,input->w);
    for(int i=0;i<node_count;i++){
        Node *n=&nodes[i];fprintf(f,"%s{\"index\":%d,\"name\":\"%s\",\"op\":\"%s\",\"a\":%d,\"b\":%d,\"shape\":[%d,%d,%d]}",
            i ? ",\n":"",i,n->name,op_names[n->op],n->a,n->b,n->shape.h,n->shape.w,n->shape.c);
    }
    fputs("],\"heads\":[",f);for(int i=0;i<3;i++)fprintf(f,"%s{\"stride\":%d,\"box_node\":%d,\"cls_node\":%d,\"s_box\":%.9g,\"s_cls\":%.9g,\"multL\":%d,\"shiftL\":%d}",
        i ? ",":"",8<<i,head_box[i],head_cls[i],g_sig[i].s_box,g_sig[i].s_cls,g_sig[i].multL,g_sig[i].shiftL);
    fputs("],\"sigmoid_y\":[",f);for(int i=0;i<32;i++)fprintf(f,"%s%d",i ? ",":"",SIG_Y[i]);
    fputs("],\"sigmoid_dy\":[",f);for(int i=0;i<32;i++)fprintf(f,"%s%d",i ? ",":"",SIG_DY[i]);fputs("]}\n",f);fclose(f);
}
static void export_golden(Tensor *input,int limit,int verify){
    Tensor values[99];char path[80];
    for(int i=0;i<limit;i++){
        Node *n=&nodes[i];const Tensor *a=n->a<0 ? input:&values[n->a],*b=n->b<0 ? input:&values[n->b];
        switch(n->op){
            case N_CONV:values[i]=conv_layer(a,n->name);break;
            case N_ADD:values[i]=add_point(a,b,n->name);break;
            case N_CAT:values[i]=concat2(a,b);break;
            case N_POOL:values[i]=maxpool5(a);break;
            default:values[i]=upsample2x(a);break;
        }
        require(values[i].h==n->shape.h && values[i].w==n->shape.w && values[i].c==n->shape.c,"C output shape");
        snprintf(path,80,"golden/layer%03d.bin",i);write_tensor(path,&values[i],1);
        fprintf(stderr,"[golden] %d/%d %s\n",i+1,limit,n->name);fflush(stderr);
    }
    int compared=0;
    if(verify){
        require(limit==99,"full comparison needs 99 tensors");
        // 保留values供比较，重新清空原C点表后独立调用原始高层前向。
        g_npts=0;g_reg_n=0;Det dets[300];int nd=forward_fixed(input,dets,300);
        require(g_npts==83,"original forward point count");
        for(int p=0;p<g_npts;p++){
            if(strcmp(g_pts[p].name,"input")==0)continue;
            int index=-1;for(int i=0;i<99;i++)if(strcmp(nodes[i].name,g_pts[p].name)==0){index=i;break;}
            require(index>=0,"original point missing from graph");Tensor *a=&values[index],*b=&g_pts[p].t;
            require(a->h==b->h && a->w==b->w && a->c==b->c && memcmp(a->d,b->d,(size_t)a->h*a->w*a->c*2)==0,"original forward numerical mismatch");compared++;
        }
        require(compared==82,"comparison coverage");FILE *f=open_file("detections.json","w");fputs("[",f);
        for(int i=0;i<nd;i++)fprintf(f,"%s{\"class_id\":%d,\"score\":%.9g,\"box\":[%.9g,%.9g,%.9g,%.9g]}",i ? ",":"",dets[i].cls,dets[i].score,dets[i].x1,dets[i].y1,dets[i].x2,dets[i].y2);
        fputs("]\n",f);fclose(f);
    }
    FILE *f=open_file("reference_result.json","w");fprintf(f,"{\"passed\":true,\"golden_tensors\":%d,\"original_forward_compared\":%s,\"compared_conv_add_points\":%d,\"q13_clamps\":%lld}\n",limit,verify ? "true":"false",compared,(long long)g_sat_clamp);fclose(f);
}
int main(int argc,char **argv){
    if(argc!=6){fprintf(stderr,"usage: exporter weights.bin size input_hwc.bin|- golden_limit verify_forward\n");return 2;}
    int size=atoi(argv[2]),limit=atoi(argv[4]),verify=atoi(argv[5]);
    require(size>=32 && size<=256 && size%32==0 && limit>=0 && limit<=99 && (!verify || limit==99),"arguments");
    load_bin(argv[1]);require(g_nconv==72 && g_nadd==10 && g_nsig==3,"asset counts");
    input_shape=(Shape){size,size,3};build_graph();Tensor input=t_alloc(3,size,size);
    if(strcmp(argv[3],"-")==0){for(int y=0;y<size;y++)for(int x=0;x<size;x++)for(int c=0;c<3;c++)t_set(&input,c,y,x,(i16)((y*7+x*3+c*53)&255));}
    else {
        FILE *f=open_file(argv[3],"rb");for(int y=0;y<size;y++)for(int x=0;x<size;x++)for(int c=0;c<3;c++){
            int lo=fgetc(f),hi=fgetc(f);require(lo!=EOF && hi!=EOF,"input too short");i16 v=(i16)(lo|(hi<<8));require(v>=0 && v<=255,"input pixel range");t_set(&input,c,y,x,v);
        }
        require(fgetc(f)==EOF,"input too long");fclose(f);
    }
    export_spec(&input);if(limit)export_golden(&input,limit,verify);
    printf("EXPORT network tasks=%d size=%d golden=%d\n",node_count,size,limit);return 0;
}
