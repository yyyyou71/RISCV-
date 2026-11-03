#define _POSIX_C_SOURCE 200809L
#include "image_input.h"
#include "comm_protocol.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_ONLY_PNM
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_MAX_DIMENSIONS 16384
#include "third_party/stb_image.h"

static int supported(const char *path){
    const char *e=strrchr(path,'.');
    return e&&(!strcasecmp(e,".jpg")||!strcasecmp(e,".jpeg")||!strcasecmp(e,".png")||
        !strcasecmp(e,".bmp")||!strcasecmp(e,".ppm")||!strcasecmp(e,".pgm"));
}
static int append(image_list *list,const char *path){
    char *copy=strdup(path);if(!copy)return -1;
    char **paths=realloc(list->paths,((size_t)list->count+1)*sizeof(*paths));
    if(!paths){free(copy);return -1;}
    list->paths=paths;list->paths[list->count++]=copy;return 0;
}
static int compare(const void *a,const void *b){return strcmp(*(char *const *)a,*(char *const *)b);}
void image_list_close(image_list *list){
    for(unsigned i=0;i<list->count;i++)free(list->paths[i]);
    free(list->paths);list->paths=0;list->count=0;
}
int image_list_open(image_list *list,const char *path){
    struct stat st;list->paths=0;list->count=0;
    if(stat(path,&st))return -1;
    if(S_ISREG(st.st_mode))return append(list,path);
    if(!S_ISDIR(st.st_mode)){errno=EINVAL;return -1;}
    DIR *dir=opendir(path);if(!dir)return -1;
    struct dirent *entry;int error=0;
    while((entry=readdir(dir))){
        if(!supported(entry->d_name))continue;
        size_t size=strlen(path)+strlen(entry->d_name)+2;char *name=malloc(size);
        if(!name){error=errno;break;}
        snprintf(name,size,"%s/%s",path,entry->d_name);
        if(!stat(name,&st)&&S_ISREG(st.st_mode)&&append(list,name))error=errno;
        free(name);if(error)break;
    }
    closedir(dir);
    if(!error&&!list->count)error=ENOENT;
    if(error){image_list_close(list);errno=error;return -1;}
    qsort(list->paths,list->count,sizeof(*list->paths),compare);return 0;
}
uint8_t *image_load_384(const char *path){
    int width,height,channels;
    uint8_t *source=stbi_load(path,&width,&height,&channels,3);
    if(!source){fprintf(stderr,"Image decode failed: %s: %s\n",path,stbi_failure_reason());errno=EINVAL;return 0;}
    uint8_t *out=malloc(IMAGE_BYTES);
    if(!out){stbi_image_free(source);return 0;}
    // Bilinear full-image resize, pixel centers, no letterbox. Fixed-point
    // arithmetic makes the byte stream independent of host floating-point mode.
    for(unsigned y=0;y<IMAGE_HEIGHT;y++){
        int64_t sy=((int64_t)(2*y+1)*height*32768)/IMAGE_HEIGHT-32768;
        if(sy<0)sy=0;
        if(sy>((int64_t)height-1)*65536)sy=((int64_t)height-1)*65536;
        unsigned y0=(unsigned)(sy>>16),y1=y0+1<(unsigned)height?y0+1:y0,fy=(unsigned)sy&65535;
        for(unsigned x=0;x<IMAGE_WIDTH;x++){
            int64_t sx=((int64_t)(2*x+1)*width*32768)/IMAGE_WIDTH-32768;
            if(sx<0)sx=0;
            if(sx>((int64_t)width-1)*65536)sx=((int64_t)width-1)*65536;
            unsigned x0=(unsigned)(sx>>16),x1=x0+1<(unsigned)width?x0+1:x0,fx=(unsigned)sx&65535;
            for(unsigned c=0;c<3;c++){
                uint64_t a=(uint64_t)source[((size_t)y0*width+x0)*3+c]*(65536-fx)+
                           (uint64_t)source[((size_t)y0*width+x1)*3+c]*fx;
                uint64_t b=(uint64_t)source[((size_t)y1*width+x0)*3+c]*(65536-fx)+
                           (uint64_t)source[((size_t)y1*width+x1)*3+c]*fx;
                out[(y*IMAGE_WIDTH+x)*3+c]=(uint8_t)((a*(65536-fy)+b*fy+((uint64_t)1<<31))>>32);
            }
        }
    }
    stbi_image_free(source);return out;
}
