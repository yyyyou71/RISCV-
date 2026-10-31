#include "rk_fspi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
int main(int argc,char **argv) {
    rk_fspi d={.fd=-1};uint8_t data[2048];
    unsigned long n;char *end;size_t i;int rc=1,reading;
    if(argc!=4 || (strcmp(argv[2],"write") && strcmp(argv[2],"read"))) {
        fprintf(stderr,"Usage: %s /dev/spidev4.0 write|read SIZE (1..2048)\nCPU must ARM_RX before write, COMMIT_TX before read. No implicit loopback.\n",argv[0]);return 1;
    }
    errno=0;n=strtoul(argv[3],&end,0);
    if(errno || !argv[3][0] || *end || n<1 || n>2048)return 1;
    reading=!strcmp(argv[2],"read");
    for(i=0;i<n;i++)data[i]=(uint8_t)((i*37u)^0xa5u);
    fprintf(stderr,"FSPI_MAIN_FSP2 device=%s 50MHz mode3 %s bytes=%lu\n",argv[1],argv[2],n);
    if(rk_fspi_open(&d,argv[1],50000000)<0){perror("FSPI open");return 1;}
    if((reading?rk_fspi_read(&d,data,n):rk_fspi_write(&d,data,n))<0){perror("FSPI transfer");goto done;}
    if(reading){for(i=0;i<n;i++)printf("%02x%c",data[i],(i%16==15 || i+1==n)?'\n':' ');}
    printf("Transferred %lu bytes; confirm CPU ownership/status for application success.\n",n);rc=0;
done:rk_fspi_close(&d);return rc;
}
