#define main cli_main
#include "rk_comm_cli.c"
#undef main
#include <assert.h>
#include <stdarg.h>
static uint8_t ctrl_reply[8],sent[2048],answer[2048];
static unsigned pos,count,rxsize,ansize,writes,reads,committed,appstate;
static int corrupt,write_error;
int __wrap_flock(int fd,int operation){(void)fd;(void)operation;return 0;}
int rk_iic_open(rk_iic *d,const char *p,uint8_t a){(void)p;d->fd=10;d->address=a;return 0;}
void rk_iic_close(rk_iic *d){d->fd=-1;}
int rk_fspi_open(rk_fspi *d,const char *p,uint32_t hz){(void)p;assert(hz==50000000);d->fd=11;return 0;}
void rk_fspi_close(rk_fspi *d){d->fd=-1;}
int rk_iic_peek(rk_iic *d,uint8_t *v){(void)d;if(!count)return 0;*v=ctrl_reply[pos];return 1;}
int rk_iic_consume(rk_iic *d){(void)d;assert(count);pos++;count--;return 0;}
int rk_iic_set_parameter(rk_iic *d,uint32_t v){
 uint32_t result=0;unsigned op=v>>24;(void)d;assert(count==0);
 if(op==COMM_INFO)result=COMM_ABI;
 else if(op==COMM_ARM){assert(appstate==COMM_IDLE);rxsize=v&65535u;appstate=COMM_RX;result=rxsize;}
 else{assert(op==COMM_POLL);result=appstate|(ansize<<16);}
 ctrl_reply[0]=0xc3;ctrl_reply[1]=(uint8_t)(v>>16);ctrl_reply[2]=0;ctrl_reply[3]=1;
 comm_put32(ctrl_reply+4,result);count=8;pos=0;return 0;
}
int rk_fspi_write(rk_fspi *d,const uint8_t *p,size_t n){
 unsigned op;uint16_t len=0;(void)d;writes++;assert(appstate==COMM_RX && n==rxsize);assert(comm_valid(p,n));
 if(write_error){errno=EIO;return -1;}
 memcpy(sent,p,n);op=comm_u16(p+8);
 if(op==COMM_SET_PARAM){assert(comm_u32(p+16)==0);assert(comm_u32(p+20)==3);committed++;comm_put32(answer+16,3);len=4;}
 else if(op==COMM_GET_PARAM){comm_put32(answer+16,3);len=4;}
 else if(op==COMM_GET_STATUS){memset(answer+16,0,24);comm_put32(answer+16,COMM_ABI);len=24;}
 else{assert(op==COMM_READ_LOG);memcpy(answer+16,"cpu\n",4);len=4;}
 comm_seal(answer,comm_u32(p+4),0,len);ansize=16+len;appstate=COMM_TX;return 0;
}
int rk_fspi_read(rk_fspi *d,uint8_t *p,size_t n){(void)d;reads++;assert(appstate==COMM_TX && n==ansize);memcpy(p,answer,n);if(corrupt)p[12]^=1;appstate=COMM_IDLE;return 0;}
static void reset_mock(void){pos=count=rxsize=ansize=writes=reads=committed=appstate=0;corrupt=write_error=0;}
int main(void){
 char *set[]={"rk_comm_cli","i2c","spi","set","0","3",0};
 char *get[]={"rk_comm_cli","i2c","spi","get","0",0};
 char *status[]={"rk_comm_cli","i2c","spi","status",0};
 char *logs[]={"rk_comm_cli","i2c","spi","logs",0};
 char *bad[]={"rk_comm_cli","i2c","spi","set","16","3",0};
 reset_mock();assert(cli_main(6,set)==0 && writes==1 && reads==1 && committed==1);
 reset_mock();assert(cli_main(5,get)==0 && reads==1);
 reset_mock();assert(cli_main(4,status)==0);
 reset_mock();assert(cli_main(4,logs)==0);
 reset_mock();assert(cli_main(6,bad)==2 && !writes);
 reset_mock();write_error=1;assert(cli_main(6,set)==1 && writes==1 && !reads);
 reset_mock();corrupt=1;assert(cli_main(6,set)==1 && writes==1 && reads==1 && committed==1);
 puts("PASS: host commands, IIC ownership handshake, packet checksum, bounds, no retry on uncertain transfers");return 0;
}
