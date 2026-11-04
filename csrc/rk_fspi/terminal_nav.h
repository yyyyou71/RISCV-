#ifndef TERMINAL_NAV_H
#define TERMINAL_NAV_H
#include <sys/select.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
/* Commands are queued during hardware work and consumed only at frame boundaries. */
typedef struct {unsigned index,count;int requested,quit,eof,overflow;unsigned used;char line[64];} terminal_nav;
static void terminal_nav_help(void){puts("[browse] n/next = next, p/prev = previous, q/quit = exit (press Enter). Commands during inference apply after this frame.");}
static void terminal_nav_command(terminal_nav *nav){
    char *s=nav->line;while(*s==' '||*s=='\t')s++;
    size_t n=strlen(s);while(n&&(s[n-1]==' '||s[n-1]=='\t'||s[n-1]=='\r'))s[--n]=0;
    if(!n)return;
    if(!strcmp(s,"q")||!strcmp(s,"quit")||!strcmp(s,"exit")){nav->quit=1;puts("[browse] exit requested; finishing the current frame.");}
    else if(!strcmp(s,"n")||!strcmp(s,"next")){if(nav->count)nav->index=(nav->index+1)%nav->count;nav->requested=1;}
    else if(!strcmp(s,"p")||!strcmp(s,"prev")||!strcmp(s,"previous")){if(nav->count)nav->index=nav->index?nav->index-1:nav->count-1;nav->requested=1;}
    else terminal_nav_help();
}
static int terminal_nav_poll(terminal_nav *nav){
    if(nav->eof||nav->quit)return 0;
    for(;;){
        fd_set fds;FD_ZERO(&fds);FD_SET(STDIN_FILENO,&fds);struct timeval wait={0,0};
        int ready=select(STDIN_FILENO+1,&fds,0,0,&wait);
        if(ready<0){if(errno==EINTR)return 0;return -1;}if(!ready)return 0;
        char c;ssize_t n=read(STDIN_FILENO,&c,1);
        if(n<0){if(errno==EINTR||errno==EAGAIN)return 0;return -1;}
        if(!n){nav->eof=nav->quit=1;puts("[browse] terminal input closed; finishing the current frame.");return 0;}
        if(c=='\n'){
            if(!nav->overflow){nav->line[nav->used]=0;terminal_nav_command(nav);}
            else puts("[browse] command too long; use n, p or q.");
            nav->used=0;nav->overflow=0;if(nav->quit)return 0;
        }else if(nav->used+1<sizeof(nav->line))nav->line[nav->used++]=c;
        else nav->overflow=1;
    }
}
#endif
