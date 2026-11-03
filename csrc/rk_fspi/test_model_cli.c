#ifdef TEST_RK_CONTROL
#include "rk_control.c"
static int model_main(int argc,char **argv){
    (void)argc;
    uint32_t v[COMM_NETWORK_WORDS];uint8_t payload[4],reply[SPI_TERM_PAYLOAD];unsigned bytes;
    if(rk_control_open(argv[1]))return 1;
    int result;
    if(!strcmp(argv[2],"load") || !strcmp(argv[2],"resume"))result=rk_control_upload(argv[3],!strcmp(argv[2],"resume"));
    else{
        result=rk_control_status(COMM_NETWORK_STATUS,COMM_NETWORK_ABI,v,COMM_NETWORK_WORDS);
        if(!result && !strcmp(argv[2],"results"))result=rk_control_results(v[10],v[9]);
        else if(!result && (!strcmp(argv[2],"infer") || !strcmp(argv[2],"abort"))){
            comm_put32(payload,v[3]);
            result=rk_control_exchange(!strcmp(argv[2],"infer")?COMM_NETWORK_RUN:COMM_MODEL_ABORT,
                payload,4,reply,sizeof(reply),&bytes);
        }
    }
    rk_control_close();return result?1:0;
}
#else
#define main model_main
#include "rk_model_cli.c"
#undef main
#endif
#include <assert.h>
static uint32_t values[COMM_NETWORK_WORDS],rolling;
static uint8_t answer[SPI_TERM_FRAME];
static unsigned requests,pending,chunks;
static int interrupt_chunk,corrupt_reply;
static int reject_commit,log_pending;
static unsigned logs_read;
int __wrap_flock(int fd,int operation){(void)fd;(void)operation;return 0;}
int rk_fspi_open(rk_fspi *d,const char *p,uint32_t hz){(void)p;assert(hz==50000000);d->fd=11;return 0;}
void rk_fspi_close(rk_fspi *d){d->fd=-1;}
int rk_fspi_write(rk_fspi *d,const uint8_t *p,size_t n){
    unsigned op=comm_u16(p+8),bytes=comm_u16(p+10),payload=COMM_NETWORK_WORDS*4;
    (void)d;assert(n==SPI_TERM_FRAME && spi_term_valid(p) && !pending);requests++;
    if(op==COMM_MODEL_BEGIN){
        values[1]=NW_LOADING;values[3]=comm_u32(p+16);values[6]=comm_u32(p+20);
        values[8]=comm_u32(p+24);values[5]=0;rolling=2166136261u;
    }else if(op==COMM_MODEL_CHUNK){
        assert(values[1]==NW_LOADING && comm_u32(p+16)==values[3] && comm_u32(p+20)==values[5]);
        for(unsigned i=0;i<bytes-8;i++)assert(p[24+i]==(uint8_t)((values[5]+i)%251));
        rolling=hash_bytes(rolling,p+24,bytes-8);values[5]+=bytes-8;chunks++;
    }else if(op==COMM_MODEL_COMMIT){
        assert(values[5]==values[6] && rolling==values[8]);values[7]=rolling;values[1]=NW_READY;values[23]=1;
        if(reject_commit){values[1]=NW_ERROR;values[2]=0x1003u;values[23]=0;log_pending=1;}
    }else if(op==COMM_NETWORK_RUN){values[1]=NW_QUEUED;values[9]=1;values[10]=42;}
    else if(op==COMM_MODEL_ABORT){values[1]=NW_EMPTY;values[23]=0;}
    else if(op==COMM_DETECTIONS){payload=56;}
    else assert(op==COMM_NETWORK_STATUS);
    memset(answer,0,sizeof(answer));comm_put32(answer+16,0);comm_put32(answer+20,op);
    if(op==COMM_MODEL_COMMIT && reject_commit)comm_put32(answer+16,COMM_BAD_ARGUMENT);
    if(op==COMM_DETECTIONS){
        comm_put32(answer+24,values[3]);comm_put32(answer+28,values[9]);comm_put32(answer+32,42);
        comm_put32(answer+36,1);comm_put32(answer+40,0);comm_put32(answer+44,1);
        for(unsigned i=0;i<4;i++)comm_put32(answer+48+i*4,(i+1)*65536);
        comm_put32(answer+64,32768);comm_put32(answer+68,2);
    }else for(unsigned i=0;i<COMM_NETWORK_WORDS;i++)comm_put32(answer+24+i*4,values[i]);
    spi_term_seal(answer,comm_u32(p+4),SPI_TERM_RESPONSE,(uint16_t)(payload+8));pending=1;
    if(op==COMM_MODEL_CHUNK && interrupt_chunk && chunks==3){interrupt_chunk=0;errno=EIO;return -1;}
    return 0;
}
int rk_fspi_read(rk_fspi *d,uint8_t *p,size_t n){
    (void)d;assert(n==SPI_TERM_FRAME);
    if(pending){memcpy(p,answer,n);pending=0;if(corrupt_reply)p[12]^=1;return 0;}
    if(log_pending){
        const char *message="Model validation failed: model: 314d4940 post: 31504941\n";
        memset(p,0,n);memcpy(p+16,message,strlen(message));
        spi_term_seal(p,0,SPI_TERM_LOG,(uint16_t)strlen(message));log_pending=0;logs_read++;return 0;
    }
    memset(p,0,n);comm_put32(p+16,SPI_TERM_ABI);comm_put32(p+20,SPI_TERM_FRAME);comm_put32(p+24,4);
    spi_term_seal(p,0,SPI_TERM_READY,24);return 0;
}
static void reset_mock(void){memset(values,0,sizeof(values));values[0]=COMM_NETWORK_ABI;requests=pending=chunks=0;interrupt_chunk=corrupt_reply=0;reject_commit=log_pending=0;logs_read=0;}
int main(void){
    char path[]="/tmp/rk_model_test_XXXXXX";int fd=mkstemp(path);assert(fd>=0);FILE *f=fdopen(fd,"wb");assert(f);
    for(unsigned i=0;i<0x12000;i++)assert(fputc(i%251,f)!=EOF);
    assert(!fclose(f));
    char *load[]={"rk_model_cli","spi","load",path,0};
    char *resume[]={"rk_model_cli","spi","resume",path,0};
    char *status[]={"rk_model_cli","spi","status",0};
    char *infer[]={"rk_model_cli","spi","infer",0};
    char *records[]={"rk_model_cli","spi","results",0};
    reset_mock();assert(model_main(4,load)==0 && values[1]==NW_READY && values[5]==0x12000);
    assert(model_main(3,infer)==0 && values[1]==NW_QUEUED);
    values[1]=NW_DONE;values[18]=1;assert(model_main(3,records)==0);
    reset_mock();interrupt_chunk=1;assert(model_main(4,load)==1 && chunks==3);
    assert(model_main(4,resume)==0 && values[1]==NW_READY && values[5]==0x12000);
    unsigned before=requests;corrupt_reply=1;assert(model_main(3,status)==1 && requests==before+1);
#ifdef TEST_RK_CONTROL
    reset_mock();reject_commit=1;assert(model_main(4,load)==1 && values[1]==NW_ERROR && logs_read==1);
    assert(requests==chunks+2); /* BEGIN + chunks + COMMIT; no writes after rejection. */
#endif
    unlink(path);
    puts("PASS RK model client: fixed frames, persistent RX credit, upload/hash/offsets, uncertain-write explicit resume, frame-bound results, CRC no replay");
    return 0;
}
