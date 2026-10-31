#define main cli_main
#include "rk_comm_cli.c"
#undef main
#include <assert.h>
static uint8_t sent[SPI_TERM_FRAME],answer[SPI_TERM_FRAME];
static unsigned phase,writes,reads,committed;
static int corrupt,write_error;
int __wrap_flock(int fd,int operation){(void)fd;(void)operation;return 0;}
int rk_fspi_open(rk_fspi *d,const char *p,uint32_t hz){(void)p;assert(hz==50000000);d->fd=11;return 0;}
void rk_fspi_close(rk_fspi *d){d->fd=-1;}
int rk_fspi_write(rk_fspi *d,const uint8_t *p,size_t n){
 unsigned op;uint16_t len=0;(void)d;
 writes++;assert(phase==3 && n==SPI_TERM_FRAME && spi_term_valid(p));
 if(write_error){errno=EIO;return -1;}
 memcpy(sent,p,n);op=comm_u16(p+8);memset(answer,0,sizeof(answer));
 comm_put32(answer+16,COMM_OK);comm_put32(answer+20,op);
 if(op==COMM_SET_PARAM){
  assert(comm_u32(p+16)==0 && comm_u32(p+20)==3);committed++;
  comm_put32(answer+24,3);len=4;
 }else if(op==COMM_GET_PARAM){comm_put32(answer+24,3);len=4;}
 else if(op==COMM_GET_STATUS){comm_put32(answer+24,SPI_TERM_ABI);len=24;}
 else if(op==COMM_AI_STATUS){
  len=COMM_AI_WORDS*4;comm_put32(answer+24,COMM_AI_ABI);comm_put32(answer+28,9);
  comm_put32(answer+24+13*4,32);comm_put32(answer+24+14*4,0xffffffffu);
 }
 else{
  assert(op>=COMM_VIDEO_STATUS && op<=COMM_VIDEO_RELEASE && comm_u16(p+10)==0);
  len=COMM_VIDEO_WORDS*4;comm_put32(answer+24,COMM_VIDEO_ABI);
  comm_put32(answer+28,op==COMM_VIDEO_STATUS?COMM_VIDEO_ERROR:
   op==COMM_VIDEO_RETRY?COMM_VIDEO_WAIT_DDR:COMM_VIDEO_IDLE);
  comm_put32(answer+32,op==COMM_VIDEO_STATUS?2:0);
  comm_put32(answer+24+5*4,(1080u<<16)|1920u);
  comm_put32(answer+24+6*4,416667);
 }
 spi_term_seal(answer,comm_u32(p+4),SPI_TERM_RESPONSE,len+8);return 0;
}
int rk_fspi_read(rk_fspi *d,uint8_t *p,size_t n){
 (void)d;reads++;assert(n==SPI_TERM_FRAME);
 memset(p,0,SPI_TERM_FRAME);
 if(phase==0){memset(p,255,SPI_TERM_FRAME);phase++;return 0;}
 if(phase==1){memcpy(p+16,"cpu\n",4);spi_term_seal(p,1,SPI_TERM_LOG,4);phase++;return 0;}
 if(phase==2){
  comm_put32(p+16,SPI_TERM_ABI);comm_put32(p+20,SPI_TERM_FRAME);comm_put32(p+24,4);
  spi_term_seal(p,2,SPI_TERM_READY,24);phase++;return 0;
 }
 assert(writes==1);memcpy(p,answer,n);if(corrupt)p[12]^=1;return 0;
}
static void reset_mock(void){phase=writes=reads=committed=0;corrupt=write_error=0;}
int main(void){
 char *set[]={"rk_comm_cli","spi","set","0","3",0};
 char *get[]={"rk_comm_cli","spi","get","0",0};
 char *status[]={"rk_comm_cli","spi","status",0};
 char *once[]={"rk_comm_cli","spi","once",0};
 char *bad[]={"rk_comm_cli","spi","set","16","3",0};
 char *video[]={"rk_comm_cli","spi","video-status",0};
 char *retry[]={"rk_comm_cli","spi","video-retry",0};
 char *release[]={"rk_comm_cli","spi","video-release",0};
 char *ai[]={"rk_comm_cli","spi","ai-status",0};
 reset_mock();assert(cli_main(5,set)==0 && writes==1 && committed==1);
 reset_mock();assert(cli_main(4,get)==0 && writes==1);
 reset_mock();assert(cli_main(3,status)==0);
 reset_mock();assert(cli_main(3,once)==0 && writes==0 && reads==2);
 reset_mock();assert(cli_main(3,video)==0 && writes==1 && comm_u16(sent+8)==COMM_VIDEO_STATUS);
 reset_mock();assert(cli_main(3,retry)==0 && writes==1 && comm_u16(sent+8)==COMM_VIDEO_RETRY);
 reset_mock();assert(cli_main(3,release)==0 && writes==1 && comm_u16(sent+8)==COMM_VIDEO_RELEASE);
 reset_mock();assert(cli_main(3,ai)==0 && writes==1 && comm_u16(sent+8)==COMM_AI_STATUS);
 reset_mock();assert(cli_main(5,bad)==2 && !writes);
 reset_mock();write_error=1;assert(cli_main(5,set)==1 && writes==1);
 reset_mock();corrupt=1;assert(cli_main(5,set)==1 && writes==1 && committed==1);
 puts("PASS: SPI-only ready/command/response, empty polling, terminal logs, diagnostics, checksum, bounds, no command retry");
 return 0;
}
