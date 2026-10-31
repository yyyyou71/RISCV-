#define _POSIX_C_SOURCE 200809L
#include "rk_fspi.h"
#include "../rk_iic/rk_iic.h"
#include "comm_protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>
static rk_iic control=RK_IIC_INIT;
static rk_fspi spi={.fd=-1};
static uint8_t token;
static int fail(int e){errno=e;return -1;}
static uint64_t milliseconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000u+t.tv_nsec/1000000u;}
static void pause_ms(void){struct timespec t={0,1000000};while(nanosleep(&t,&t)<0 && errno==EINTR){}}
static int control_call(unsigned op,unsigned arg,uint32_t *value){
 uint8_t reply[8],byte;unsigned used=0;uint64_t until;int rc;
 ++token;
 if(rk_iic_set_parameter(&control,((uint32_t)op<<24)|((uint32_t)token<<16)|arg))return -1;
 until=milliseconds()+3000;
 while(milliseconds()<until){
  rc=rk_iic_peek(&control,&byte);if(rc<0)return -1;
  if(!rc){pause_ms();continue;}
  if(rk_iic_consume(&control))return -1;
  if(!used && byte!=COMM_ACK_MAGIC)continue;
  reply[used++]=byte;
  if(used==8){
   used=0;if(reply[1]!=token)continue;
   if(reply[3]!=1)return fail(EPROTO);
   if(reply[2]!=COMM_OK){fprintf(stderr,"CPU control rejected: code=%u detail=%u\n",reply[2],comm_u32(reply+4));return fail(EPROTO);}
   *value=comm_u32(reply+4);return 0;
  }
 }
 return fail(ETIMEDOUT);
}
static int number(const char *s,uint32_t *v){
 char *end;unsigned long long x;errno=0;
 if(!s[0] || s[0]=='-')return -1;
 x=strtoull(s,&end,0);
 if(errno || *end || x>0xffffffffu)return -1;
 *v=(uint32_t)x;return 0;
}
int main(int argc,char **argv){
 uint8_t tx[COMM_MAX]={0},rx[COMM_MAX];uint32_t a=0,b=0,state,sequence;
 uint16_t operation,payload=0;size_t n;uint64_t deadline;int rc=1;
 if(argc<4)goto usage;
 if(!strcmp(argv[3],"status") && argc==4)operation=COMM_GET_STATUS;
 else if(!strcmp(argv[3],"set") && argc==6 && !number(argv[4],&a) && a<COMM_PARAMS && !number(argv[5],&b)){
  operation=COMM_SET_PARAM;payload=8;comm_put32(tx+16,a);comm_put32(tx+20,b);
 }else if(!strcmp(argv[3],"get") && argc==5 && !number(argv[4],&a) && a<COMM_PARAMS){
  operation=COMM_GET_PARAM;payload=4;comm_put32(tx+16,a);
 }else if(!strcmp(argv[3],"logs") && (argc==4 || (argc==5 && !number(argv[4],&a))) && a<=COMM_MAX-COMM_HEADER){
  if(argc==4)a=512;
  operation=COMM_READ_LOG;payload=4;comm_put32(tx+16,a);
 }else goto usage;
 if(rk_iic_open(&control,argv[1],0x66)){perror("IIC open");goto done;}
 if(flock(control.fd,LOCK_EX|LOCK_NB)){perror("Another communication client holds IIC");goto done;}
 if(rk_fspi_open(&spi,argv[2],50000000)){perror("SPI open");goto done;}
 if(flock(spi.fd,LOCK_EX|LOCK_NB)){perror("Another communication client holds SPI");goto done;}
 /* Discard stale control notifications only, never retry a data operation. */
 deadline=milliseconds()+3000;
 for(;;){uint8_t byte;int r=rk_iic_peek(&control,&byte);if(r<0)goto io_error;if(!r)break;
  if(rk_iic_consume(&control))goto io_error;
  if(milliseconds()>=deadline){errno=ETIMEDOUT;goto io_error;}
 }
 token=(uint8_t)(getpid()^milliseconds());
 if(control_call(COMM_INFO,0,&state))goto io_error;
 if(state!=COMM_ABI){errno=EPROTO;goto io_error;}
 if(control_call(COMM_POLL,0,&state))goto io_error;
 if((state&65535u)!=COMM_IDLE){fprintf(stderr,"CPU has pending transaction/state=%u. Reconcile it before another command.\n",state&65535u);goto done;}
 sequence=(uint32_t)(milliseconds()^((uint32_t)getpid()<<16));
 comm_seal(tx,sequence,operation,payload);
 if(control_call(COMM_ARM,COMM_HEADER+payload,&state))goto io_error;
 if(state!=COMM_HEADER+payload){errno=EPROTO;goto io_error;}
 if(rk_fspi_write(&spi,tx,COMM_HEADER+payload))goto io_error;
 deadline=milliseconds()+3000;
 do{
  if(control_call(COMM_POLL,0,&state))goto io_error;
  if((state&65535u)==COMM_TX)break;
  if((state&65535u)!=COMM_RX){errno=EPROTO;goto io_error;}
  pause_ms();
 }while(milliseconds()<deadline);
 if((state&65535u)!=COMM_TX){errno=ETIMEDOUT;goto io_error;}
 n=state>>16;if(n<COMM_HEADER || n>COMM_MAX){errno=EPROTO;goto io_error;}
 if(rk_fspi_read(&spi,rx,n))goto io_error;
 if(!comm_valid(rx,n) || comm_u32(rx+4)!=sequence){errno=EBADMSG;goto io_error;}
 if(comm_u16(rx+8)!=COMM_OK){fprintf(stderr,"CPU application error=%u\n",comm_u16(rx+8));goto done;}
 if(operation==COMM_READ_LOG){fwrite(rx+16,1,n-16,stdout);}
 else if(operation==COMM_GET_STATUS){
  if(n!=40){errno=EPROTO;goto io_error;}
  printf("ABI=%08x RX_packets=%u TX_packets=%u log_bytes=%u log_dropped=%u cycles=%u\n",
   comm_u32(rx+16),comm_u32(rx+20),comm_u32(rx+24),comm_u32(rx+28),comm_u32(rx+32),comm_u32(rx+36));
 }else{
  if(n!=20){errno=EPROTO;goto io_error;}
  printf("parameter[%u] = 0x%08x (%u)\n",a,comm_u32(rx+16),comm_u32(rx+16));
 }
 rc=0;goto done;
io_error:perror("Communication");fprintf(stderr,"No automatic retry. A failed write/read may have taken effect; pending transactions require reconciliation or coordinated reset.\n");
done:rk_fspi_close(&spi);rk_iic_close(&control);return rc;
usage:fprintf(stderr,"Usage: %s I2C_DEVICE SPI_DEVICE status|get INDEX|set INDEX VALUE|logs [MAX_BYTES]\nExample: %s /dev/i2c-0 /dev/spidev4.0 set 0 3\n",argv[0],argv[0]);return 2;
}
