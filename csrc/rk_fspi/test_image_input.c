#define _POSIX_C_SOURCE 200809L
#include "image_input.h"
#include "comm_protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void){
    char directory[]="/tmp/rk-image-test-XXXXXX",path[256];assert(mkdtemp(directory));
    snprintf(path,sizeof(path),"%s/gradient.ppm",directory);FILE *f=fopen(path,"wb");assert(f);
    fprintf(f,"P6\n384 216\n255\n");
    for(unsigned i=0;i<IMAGE_BYTES;i++)fputc((int)(i*29u)&255,f);
    assert(!fclose(f));uint8_t *p=image_load_384(path);assert(p);
    for(unsigned i=0;i<IMAGE_BYTES;i++)assert(p[i]==(uint8_t)(i*29u));
    free(p);
    image_list list;assert(!image_list_open(&list,directory)&&list.count==1&&!strcmp(list.paths[0],path));image_list_close(&list);
    snprintf(path,sizeof(path),"%s/one.ppm",directory);f=fopen(path,"wb");assert(f);
    fprintf(f,"P6\n1 1\n255\n");fputc(17,f);fputc(85,f);fputc(170,f);assert(!fclose(f));
    p=image_load_384(path);assert(p);
    for(unsigned i=0;i<IMAGE_BYTES/3;i++)assert(p[i*3]==17&&p[i*3+1]==85&&p[i*3+2]==170);
    free(p);assert(!image_list_open(&list,directory)&&list.count==2);
    for(unsigned i=0;i<list.count;i++)assert(!unlink(list.paths[i]));
    image_list_close(&list);assert(!rmdir(directory));
    puts("PASS image input: RGB ordering, identity resize, 1x1 enlargement, directory enumeration");return 0;
}
