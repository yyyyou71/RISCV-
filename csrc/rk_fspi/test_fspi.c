#include "rk_fspi.h"
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <linux/spi/spidev.h>
static uint8_t memory[2048];
static int messages,short_result,fail_message,closed;
int __wrap_open(const char *p,int flags,...) {(void)flags;assert(p);return 7;}
int __wrap_close(int fd) {assert(fd==7);closed++;return 0;}
int __wrap_ioctl(int fd,unsigned long req,...) {
    va_list ap;void *arg;assert(fd==7);
    va_start(ap,req);arg=va_arg(ap,void *);va_end(ap);
    if(req==SPI_IOC_WR_MODE32) {assert(*(uint32_t*)arg==(SPI_TX_QUAD|SPI_RX_QUAD));return 0;}
    if(req==SPI_IOC_RD_MODE32) {*(uint32_t*)arg=SPI_TX_QUAD|SPI_RX_QUAD;return 0;}
    if(req==SPI_IOC_WR_BITS_PER_WORD) {assert(*(uint8_t*)arg==8);return 0;}
    if(req==SPI_IOC_WR_MAX_SPEED_HZ) {assert(*(uint32_t*)arg==1000000);return 0;}
    assert(req==SPI_IOC_MESSAGE(2));messages++;
    struct spi_ioc_transfer *t=arg;
    assert(t[0].len==1 && t[0].tx_nbits==4 && !t[0].cs_change && !t[1].cs_change);
    assert(t[0].speed_hz==1000000 && t[1].speed_hz==1000000);
    assert(t[0].bits_per_word==8 && t[1].bits_per_word==8);
    uint8_t cmd=*(uint8_t*)(uintptr_t)t[0].tx_buf;
    assert(t[1].len>0 && t[1].len<=2048);
    if(fail_message) {errno=EIO;return -1;}
    if(short_result) return 1;
    if(cmd==0) {
        assert(t[1].tx_nbits==4 && !t[1].rx_buf);
        memcpy(memory,(void*)(uintptr_t)t[1].tx_buf,t[1].len);
    } else {
        assert(cmd==0x80 && t[1].rx_nbits==4 && !t[1].tx_buf);
        memcpy((void*)(uintptr_t)t[1].rx_buf,memory,t[1].len);
    }
    return (int)t[1].len+1;
}
int main(void) {
    rk_fspi d={.fd=-1};uint8_t tx[2048],rx[2048];int i,m;
    assert(rk_fspi_open(&d,"test",1000001)==-1 && errno==EINVAL);
    assert(rk_fspi_open(&d,"test",1000000)==0);
    assert(rk_fspi_open(&d,"test",1000000)==-1 && errno==EBUSY);
    for(i=0;i<2048;i++) tx[i]=(uint8_t)i;
    assert(rk_fspi_write(&d,tx,2048)==0 && rk_fspi_read(&d,rx,2048)==0);
    assert(!memcmp(tx,rx,2048));m=messages;
    assert(rk_fspi_write(&d,tx,2049)==-1);
    assert(rk_fspi_read(&d,rx,0)==-1);
    assert(rk_fspi_read(&d,0,1)==-1 && messages==m);
    short_result=1;assert(rk_fspi_write(&d,tx,1)==-1 && errno==EIO && messages==m+1);
    short_result=0;fail_message=1;
    assert(rk_fspi_read(&d,rx,1)==-1 && messages==m+2);
    rk_fspi_close(&d);rk_fspi_close(&d);assert(closed==1);
    assert(rk_fspi_read(&d,rx,1)==-1 && errno==EBADF);
    puts("PASS: quad mode, command/data framing, 2KB bounds, short/error no retry, close");
}
