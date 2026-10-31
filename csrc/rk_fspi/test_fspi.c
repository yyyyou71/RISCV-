#include "rk_fspi.h"
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <linux/spi/spidev.h>
static uint8_t memory[2048];
static uint32_t mode;
static int messages,short_result,fail_message,closed,fail_mode;
int __wrap_open(const char *p,int flags,...) {(void)flags;assert(p);return 7;}
int __wrap_close(int fd) {assert(fd==7);closed++;return 0;}
int __wrap_ioctl(int fd,unsigned long req,...) {
    va_list ap;void *arg;assert(fd==7);
    va_start(ap,req);arg=va_arg(ap,void *);va_end(ap);
    if(req==SPI_IOC_WR_MODE32) {
        if(fail_mode) {errno=EINVAL;return -1;}
        mode=*(uint32_t*)arg;
        assert(mode==SPI_MODE_3 || mode==(SPI_MODE_3|SPI_TX_QUAD) || mode==(SPI_MODE_3|SPI_RX_QUAD));
        return 0;
    }
    if(req==SPI_IOC_WR_BITS_PER_WORD) {assert(*(uint8_t*)arg==8);return 0;}
    if(req==SPI_IOC_WR_MAX_SPEED_HZ) {assert(*(uint32_t*)arg==50000000);return 0;}
    assert(req==SPI_IOC_MESSAGE(1));messages++;
    struct spi_ioc_transfer *t=arg;
    assert(t->len>0 && t->len<=2048 && !t->cs_change && !t->delay_usecs);
    assert(t->tx_nbits==4 && t->rx_nbits==4 && t->speed_hz==50000000 && t->bits_per_word==8);
    assert(!!t->tx_buf != !!t->rx_buf);
    if(fail_message) {errno=EIO;return -1;}
    if(short_result) return (int)t->len-1;
    if(t->tx_buf) {
        assert(mode==(SPI_MODE_3|SPI_TX_QUAD));
        memcpy(memory,(void*)(uintptr_t)t->tx_buf,t->len);
    } else {
        assert(mode==(SPI_MODE_3|SPI_RX_QUAD));
        memcpy((void*)(uintptr_t)t->rx_buf,memory,t->len);
    }
    return (int)t->len;
}
int main(void) {
    rk_fspi d={.fd=-1};uint8_t tx[2048],rx[2048];int i,m;
    assert(rk_fspi_open(&d,"test",50000001)==-1 && errno==EINVAL);
    assert(rk_fspi_open(&d,"test",50000000)==0);
    assert(rk_fspi_open(&d,"test",50000000)==-1 && errno==EBUSY);
    for(i=0;i<2048;i++) tx[i]=(uint8_t)((i*37)^0xa5);
    assert(rk_fspi_write(&d,tx,2048)==0 && rk_fspi_read(&d,rx,2048)==0);
    assert(!memcmp(tx,rx,2048));m=messages;
    assert(rk_fspi_write(&d,tx,2049)==-1);
    assert(rk_fspi_read(&d,rx,0)==-1);
    assert(rk_fspi_read(&d,0,1)==-1 && messages==m);
    fail_mode=1;assert(rk_fspi_write(&d,tx,16)==-1 && errno==EINVAL && messages==m);fail_mode=0;
    short_result=1;assert(rk_fspi_write(&d,tx,16)==-1 && errno==EIO && messages==m+1);
    short_result=0;fail_message=1;
    assert(rk_fspi_read(&d,rx,16)==-1 && errno==EIO && messages==m+2);
    rk_fspi_close(&d);rk_fspi_close(&d);assert(closed==1);
    assert(rk_fspi_read(&d,rx,1)==-1 && errno==EBADF);
    puts("PASS: SMDT mode3 directional quad, payload-only 2KB, bounds, config/short/error handling, no retry");
}
