#define _POSIX_C_SOURCE 200809L
#include "rk_fspi.h"
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
static int fail(int e) { errno=e; return -1; }
int rk_fspi_open(rk_fspi *d,const char *path,uint32_t hz) {
    uint32_t mode=SPI_MODE_3;
    uint8_t bits=8;
    int fd,saved;
    if(!d || !path || hz!=50000000) return fail(EINVAL);
    if(d->fd>=0) return fail(EBUSY);
    fd=open(path,O_RDWR|O_CLOEXEC);
    if(fd<0) return -1;
    if(ioctl(fd,SPI_IOC_WR_MODE32,&mode)<0 ||
       ioctl(fd,SPI_IOC_WR_BITS_PER_WORD,&bits)<0 ||
       ioctl(fd,SPI_IOC_WR_MAX_SPEED_HZ,&hz)<0) {
        saved=errno;close(fd);return fail(saved);
    }
    d->fd=fd;d->speed_hz=hz;return 0;
}
void rk_fspi_close(rk_fspi *d) { if(d && d->fd>=0) {close(d->fd);d->fd=-1;} }
static int transfer(rk_fspi *d,const uint8_t *tx,uint8_t *rx,size_t size) {
    struct spi_ioc_transfer tr={0};
    struct timespec gap={.tv_sec=0,.tv_nsec=10000};
    uint32_t mode;
    uint8_t bits=8;
    int result;
    if(!d || d->fd<0) return fail(EBADF);
    if(!size || size>2048 || (!tx && !rx) || (tx && rx)) return fail(EINVAL);
    /* Match smdt_spi_rw.c: mode 3 (-OH), one directional quad transfer.
       No userspace command byte. This API is for the SMDT driver, not a
       generic SPI controller that requires explicit command framing. */
    mode=SPI_MODE_3 | (rx ? SPI_RX_QUAD : SPI_TX_QUAD);
    if(ioctl(d->fd,SPI_IOC_WR_MODE32,&mode)<0 ||
       ioctl(d->fd,SPI_IOC_WR_BITS_PER_WORD,&bits)<0 ||
       ioctl(d->fd,SPI_IOC_WR_MAX_SPEED_HZ,&d->speed_hz)<0) return -1;
    tr.tx_buf=(uintptr_t)tx;tr.rx_buf=(uintptr_t)rx;tr.len=(uint32_t)size;
    tr.tx_nbits=tr.rx_nbits=4;
    tr.speed_hz=d->speed_hz;tr.bits_per_word=8;
    while(nanosleep(&gap,&gap)<0) if(errno!=EINTR) return -1;
#ifdef RK_FSPI_TRACE
    fprintf(stderr,"SMDT %s: mode=0x%x payload=%zu speed_hz=%u message_transfers=1%c",
            rx ? "READ" : "WRITE",(unsigned)mode,size,(unsigned)tr.speed_hz,10);
#endif
    result=ioctl(d->fd,SPI_IOC_MESSAGE(1),&tr);
    if(result<0) return -1; /* Never retry possibly partial transfers. */
#ifdef RK_FSPI_TRACE
    fprintf(stderr,"SMDT returned=%d expected=%zu%c",result,size,10);
#endif
    return result==(int)size ? 0 : fail(EIO);
}
int rk_fspi_write(rk_fspi *d,const uint8_t *data,size_t size) { return transfer(d,data,0,size); }
int rk_fspi_read(rk_fspi *d,uint8_t *data,size_t size) { return transfer(d,0,data,size); }
