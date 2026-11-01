/* Transport/upload reused from rk_model_cli.c; one process owns SPI. */
#define _POSIX_C_SOURCE 200809L
#include "rk_control.h"
#include "rk_fspi.h"
#include "network_status.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>

static rk_fspi model_spi={.fd=-1};
static uint32_t sequence;
static int credit,quiet;
static int (*idle_hook)(void);
void rk_control_set_idle_hook(int (*hook)(void)){idle_hook=hook;}
static uint64_t milliseconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static int fail(int e){errno=e;return -1;}
static int pause_poll(void){if(idle_hook && idle_hook())return fail(EINTR);struct timespec t={0,1000000};while(nanosleep(&t,&t)<0 && errno==EINTR){}return 0;}
static int read_packet(uint8_t *p){
    unsigned i;
    if(rk_fspi_read(&model_spi,p,SPI_TERM_FRAME))return -1;
    for(i=0;i<SPI_TERM_FRAME && p[i]==255;i++){}
    if(i==SPI_TERM_FRAME)return 0;
    if(!spi_term_valid(p))return fail(EBADMSG);
    return 1;
}
static int event(const uint8_t *p){
    unsigned kind=comm_u16(p+8),n=comm_u16(p+10);
    if(kind==SPI_TERM_LOG && !quiet){fwrite(p+16,1,n,stdout);fflush(stdout);}
    else if(kind==SPI_TERM_NETWORK && !quiet){if(network_print(p+16,n,0))return -1;}
    else if(kind==SPI_TERM_READY){
        if(n!=24 || comm_u32(p+16)!=SPI_TERM_ABI || comm_u32(p+20)!=SPI_TERM_FRAME)return fail(EPROTO);
    }else if(kind!=SPI_TERM_LOG && kind!=SPI_TERM_NETWORK && kind!=SPI_TERM_VIDEO && kind!=SPI_TERM_AI && kind!=SPI_TERM_RESPONSE)return fail(EPROTO);
    return 0;
}
static int exchange(unsigned op,const uint8_t *data,unsigned size,uint8_t *reply,unsigned *bytes){
    uint8_t packet[SPI_TERM_FRAME]={0};uint64_t until;int r;
    if(idle_hook && idle_hook())return fail(EINTR);
    if(size>SPI_TERM_PAYLOAD)return fail(EINVAL);
    if(!credit){
        until=milliseconds()+10000;
        for(;;){
            r=read_packet(packet);if(r<0)return -1;
            if(r){
                if(event(packet))return -1;
                if(comm_u16(packet+8)==SPI_TERM_READY && (comm_u32(packet+24)&4u))break;
            }
            if(milliseconds()>=until)return fail(ETIMEDOUT);
            if(pause_poll())return -1;
        }
    }
    memset(packet,0,sizeof(packet));
    if(size)memcpy(packet+16,data,size);
    spi_term_seal(packet,++sequence,(uint16_t)op,(uint16_t)size);credit=0;
    /* One write only. An explicit resume starts with the CPU's committed
       offset; an uncertain write is never silently repeated. */
    if(rk_fspi_write(&model_spi,packet,SPI_TERM_FRAME))return -1;
    until=milliseconds()+10000;
    for(;;){
        r=read_packet(packet);if(r<0)return -1;
        if(r){
            if(comm_u16(packet+8)==SPI_TERM_RESPONSE && comm_u32(packet+4)==sequence)break;
            if(event(packet))return -1;
        }
        if(milliseconds()>=until)return fail(ETIMEDOUT);
        if(pause_poll())return -1;
    }
    size=comm_u16(packet+10);
    if(size<8 || comm_u32(packet+20)!=op)return fail(EPROTO);
    credit=1; /* Firmware arms the next RX before publishing any response. */
    *bytes=size-8;if(*bytes)memcpy(reply,packet+24,*bytes);
    r=(int)comm_u32(packet+16);
    if(r!=COMM_OK){fprintf(stderr,"CPU rejected operation %u: status=%d (4=busy, 5=hardware fault).\n",op,r);return fail(r==COMM_BUSY?EBUSY:EPROTO);}
    return 0;
}
static int get_status(uint8_t *reply,uint32_t *v){
    unsigned n;
    if(exchange(COMM_NETWORK_STATUS,0,0,reply,&n))return -1;
    return network_decode(reply,n,v);
}
static uint32_t hash_bytes(uint32_t h,const uint8_t *data,size_t n){
    for(size_t i=0;i<n;i++)h=(h^data[i])*16777619u;
    return h;
}
static int upload(const char *path,int resume){
    uint8_t data[8+COMM_MODEL_CHUNK_BYTES],reply[SPI_TERM_PAYLOAD],block[4096];
    uint32_t values[COMM_NETWORK_WORDS],hash=2166136261u,session,total=0,offset=0;
    uint64_t started=milliseconds();FILE *f=fopen(path,"rb");size_t n;unsigned count;int result=-1;
    if(!f)return -1;
    while((n=fread(block,1,sizeof(block),f))){
        if(total>0x02000000u-n){errno=EFBIG;goto done;}
        total+=(uint32_t)n;hash=hash_bytes(hash,block,n);
    }
    if(ferror(f))goto done;
    if(total<=0x11900u || (total&15u)){errno=EINVAL;goto done;}
    quiet=1;
    if(resume){
        if(get_status(reply,values))goto done;
        if(values[1]!=NW_LOADING || values[6]!=total || values[8]!=hash || (values[5]&15u) || values[5]>total){errno=EINVAL;goto done;}
        session=values[3];offset=values[5];
        fprintf(stderr,"Resuming verified upload at %u/%u bytes.\n",offset,total);
    }else{
        session=(uint32_t)(milliseconds()^((uint32_t)getpid()<<16)^hash);if(!session)session=1;
        comm_put32(block,session);comm_put32(block+4,total);comm_put32(block+8,hash);comm_put32(block+12,hash);
        if(exchange(COMM_MODEL_BEGIN,block,16,reply,&count))goto done;
        if(network_decode(reply,count,values) || values[3]!=session || values[5]!=0){errno=EPROTO;goto done;}
    }
    if(fseek(f,(long)offset,SEEK_SET))goto done;
    while(offset<total){
        unsigned bytes=total-offset;if(bytes>COMM_MODEL_CHUNK_BYTES)bytes=COMM_MODEL_CHUNK_BYTES;
        comm_put32(data,session);comm_put32(data+4,offset);
        if(fread(data+8,1,bytes,f)!=bytes){errno=EIO;goto done;}
        if(exchange(COMM_MODEL_CHUNK,data,8+bytes,reply,&count))goto done;
        if(network_decode(reply,count,values) || values[3]!=session || values[5]!=offset+bytes){errno=EPROTO;goto done;}
        offset+=bytes;
        if(offset==total || offset%1048544u<COMM_MODEL_CHUNK_BYTES){
            fprintf(stderr,"\rModel upload %u/%u bytes",offset,total);fflush(stderr);
        }
    }
    comm_put32(data,session);
    if(exchange(COMM_MODEL_COMMIT,data,4,reply,&count))goto done;
    if(network_decode(reply,count,values) || values[1]!=NW_READY || !(values[23]&1u) || values[7]!=hash){errno=EPROTO;goto done;}
    fprintf(stderr,"\nUpload verified in DDR, %.3f seconds.\n",(milliseconds()-started)/1000.0);
    network_print(reply,count,1);result=0;
done:{int saved=errno;fclose(f);quiet=0;errno=saved;return result;}
}
static double original_coordinate(uint32_t raw,unsigned size){
    double value=(int32_t)raw/65536.0*size/96.0;
    return value<0?0:value>size?size:value;
}
int rk_control_results(uint32_t frame_id,uint32_t run_id){
    uint8_t reply[SPI_TERM_PAYLOAD],request[16];uint32_t v[COMM_NETWORK_WORDS];unsigned bytes;
    if(get_status(reply,v))return -1;
    if(v[1]!=NW_DONE)return fail(EBUSY);
    if(v[10]!=frame_id || v[9]!=run_id)return fail(EPROTO);
    if(v[18]>300)return fail(EPROTO);
    printf("frame_id=%u run_id=%u model_session=%08x detections=%u\n",v[10],v[9],v[3],v[18]);
    puts("class,score,model_x1,model_y1,model_x2,model_y2,original_x1,original_y1,original_x2,original_y2");
    for(unsigned start=0;start<v[18];){
        unsigned n=v[18]-start;if(n>6)n=6;
        comm_put32(request,v[3]);comm_put32(request+4,v[9]);comm_put32(request+8,start);comm_put32(request+12,n);
        if(exchange(COMM_DETECTIONS,request,16,reply,&bytes))return -1;
        if(bytes!=24+n*32 || comm_u32(reply)!=v[3] || comm_u32(reply+4)!=v[9] ||
           comm_u32(reply+8)!=v[10] || comm_u32(reply+12)!=v[18] || comm_u32(reply+16)!=start || comm_u32(reply+20)!=n)return fail(EPROTO);
        for(unsigned i=0;i<n;i++){
            const uint8_t *d=reply+24+i*32;
            if(comm_u32(d+28) || comm_u32(d+16)>65535 || comm_u32(d+20)>=128)return fail(EPROTO);
            printf("%u,%.6f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f\n",comm_u32(d+20),comm_u32(d+16)/65536.0,
              (int32_t)comm_u32(d)/65536.0,(int32_t)comm_u32(d+4)/65536.0,(int32_t)comm_u32(d+8)/65536.0,(int32_t)comm_u32(d+12)/65536.0,
              original_coordinate(comm_u32(d),1920),original_coordinate(comm_u32(d+4),1080),
              original_coordinate(comm_u32(d+8),1920),original_coordinate(comm_u32(d+12),1080));
        }
        start+=n;
    }
    return 0;
}

int rk_control_open(const char *device){
    credit=quiet=0;sequence=(uint32_t)(milliseconds()^((uint32_t)getpid()<<16));
    if(rk_fspi_open(&model_spi,device,50000000))return -1;
    if(flock(model_spi.fd,LOCK_EX|LOCK_NB)){
        int saved=errno;rk_fspi_close(&model_spi);errno=saved;return -1;
    }
    return 0;
}
void rk_control_close(void){rk_fspi_close(&model_spi);}
int rk_control_exchange(unsigned op,const uint8_t *request,unsigned size,
                        uint8_t *reply,unsigned capacity,unsigned *bytes){
    uint8_t packet[SPI_TERM_PAYLOAD];unsigned n=0;
    if(!bytes || (capacity&&!reply) || (size&&!request))return fail(EINVAL);
    if(exchange(op,request,size,packet,&n))return -1;
    if(n>capacity)return fail(EMSGSIZE);
    if(n)memcpy(reply,packet,n);
    *bytes=n;return 0;
}
int rk_control_status(unsigned op,uint32_t abi,uint32_t *values,unsigned words){
    uint8_t reply[SPI_TERM_PAYLOAD];unsigned n;
    if(!words || words>sizeof(reply)/4 || !values)return fail(EINVAL);
    if(rk_control_exchange(op,0,0,reply,sizeof(reply),&n))return -1;
    if(n!=words*4 || comm_u32(reply)!=abi)return fail(EPROTO);
    for(unsigned i=0;i<words;i++)values[i]=comm_u32(reply+i*4);
    return 0;
}
int rk_control_upload(const char *path,int resume){return upload(path,resume);}
