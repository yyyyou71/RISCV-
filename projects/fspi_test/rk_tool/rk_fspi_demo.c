#include "rk_fspi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
int main(int argc,char **argv) {
    rk_fspi d={.fd=-1};uint8_t tx[2048],rx[2048];
    unsigned long n;char *end;size_t i;int ret=1;
    if(argc!=3) {fprintf(stderr,"Usage: %s /dev/spidevN.N SIZE (1..2048); overwrites FPGA buffer%c",argv[0],10);return 1;}
    errno=0;n=strtoul(argv[2],&end,0);
    if(errno || !argv[2][0] || *end || n<1 || n>2048) return 1;
    for(i=0;i<n;i++) tx[i]=(uint8_t)((i*37u)^0xa5u);
    if(rk_fspi_open(&d,argv[1],1000000)<0) {perror("quad spidev open/configuration");return 1;}
    if(rk_fspi_write(&d,tx,n)<0 || rk_fspi_read(&d,rx,n)<0) {perror("FSPI transfer");goto done;}
    for(i=0;i<n;i++) if(tx[i]!=rx[i]) {
        fprintf(stderr,"Mismatch at %zu: wrote %02x read %02x%c",i,tx[i],rx[i],10);goto done;
    }
    printf("PASS: %lu bytes quad FSPI loopback at 1 MHz%c",n,10);ret=0;
done:rk_fspi_close(&d);return ret;
}
