#define _POSIX_C_SOURCE 200809L
#include "rk_fspi.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
static int fail(int e) { errno=e; return -1; }
int rk_fspi_open(rk_fspi *d,const char *path,uint32_t hz) {
    uint32_t mode=SPI_MODE_0|SPI_TX_QUAD|SPI_RX_QUAD,actual=0;
    uint8_t bits=8;
    int fd,saved;
    if(!d || !path || !hz || hz>1000000) return fail(EINVAL);
    if(d->fd>=0) return fail(EBUSY);
    fd=open(path,O_RDWR|O_CLOEXEC);
    if(fd<0) return -1;
    if(ioctl(fd,SPI_IOC_WR_MODE32,&mode)<0 || ioctl(fd,SPI_IOC_RD_MODE32,&actual)<0 ||
       ioctl(fd,SPI_IOC_WR_BITS_PER_WORD,&bits)<0 || ioctl(fd,SPI_IOC_WR_MAX_SPEED_HZ,&hz)<0)
        goto error;
    if(actual!=mode) { errno=EPROTO; goto error; }
    d->fd=fd;d->speed_hz=hz;return 0;
error:
    saved=errno;close(fd);return fail(saved);
}
void rk_fspi_close(rk_fspi *d) { if(d && d->fd>=0) {close(d->fd);d->fd=-1;} }
static int transfer(rk_fspi *d,const uint8_t *tx,uint8_t *rx,size_t size) {
    uint8_t cmd=rx ? 0x80 : 0x00;
    struct spi_ioc_transfer tr[2]={{0},{0}};
    struct timespec gap={.tv_sec=0,.tv_nsec=10000};
    int result;
    if(!d || d->fd<0) return fail(EBADF);
    if(!size || size>2048 || (!tx && !rx) || (tx && rx)) return fail(EINVAL);
    tr[0].tx_buf=(uintptr_t)&cmd;tr[0].len=1;tr[0].tx_nbits=4;
    tr[1].tx_buf=(uintptr_t)tx;tr[1].rx_buf=(uintptr_t)rx;tr[1].len=(uint32_t)size;
    tr[1].tx_nbits=tx ? 4 : 0;tr[1].rx_nbits=rx ? 4 : 0;
    tr[0].speed_hz=tr[1].speed_hz=d->speed_hz;
    tr[0].bits_per_word=tr[1].bits_per_word=8;
    /* Both segments in one message: CS stays asserted across command/data. */
    while(nanosleep(&gap,&gap)<0) if(errno!=EINTR) return -1;
    result=ioctl(d->fd,SPI_IOC_MESSAGE(2),tr);
    if(result<0) return -1; /* Do not automatically retry partial writes. */
    return result==(int)(size+1) ? 0 : fail(EIO);
}
int rk_fspi_write(rk_fspi *d,const uint8_t *data,size_t size) { return transfer(d,data,0,size); }
int rk_fspi_read(rk_fspi *d,uint8_t *data,size_t size) { return transfer(d,0,data,size); }
