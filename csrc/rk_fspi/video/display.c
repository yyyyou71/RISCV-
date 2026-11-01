/*
 * 显示模块 - 通过 dlopen 加载 SDL2，不依赖 libsdl2-dev 头文件
 * 回退: 保存为 PPM 图片
 */

#include "display.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <errno.h>

// ==================== SDL2 常量（从 SDL2 源码提取） ====================
#define MY_SDL_INIT_VIDEO           0x00000020u
#define MY_SDL_WINDOW_SHOWN         0x00000004u
#define MY_SDL_WINDOWPOS_UNDEFINED  0x1FFF0000u
// 原始代码: #define MY_SDL_PIXELFORMAT_ARGB8888 0x16362004u
//++ [改动] RGB565: FPGA通过16-bit FIFO传输, 每像素2字节
#define MY_SDL_PIXELFORMAT_ARGB8888 0x16362004u  // 保留供升级ARGB时使用
#define MY_SDL_PIXELFORMAT_RGB565   0x15151002u
//-- [改动] 结束
#define MY_SDL_TEXTUREACCESS_STREAMING 1
#define MY_SDL_RENDERER_ACCELERATED 0x00000002u
#define MY_SDL_RENDERER_PRESENTVSYNC 0x00000004u
#define MY_SDL_RENDERER_SOFTWARE    0x00000001u
#define MY_SDL_QUIT_EVENT           0x100u

// VSYNC 开关：1=开(防撕裂,但 RenderPresent 阻塞等同步,会压帧率)
//             0=关(最高帧率,追求视频吞吐用这个)
#ifndef DISPLAY_USE_VSYNC
#define DISPLAY_USE_VSYNC 0
#endif

// ==================== SDL2 函数指针 ====================
typedef int   (*fn_SDL_Init)(uint32_t);
typedef void* (*fn_SDL_CreateWindow)(const char*, int, int, int, int, uint32_t);
typedef void* (*fn_SDL_CreateRenderer)(void*, int, uint32_t);
typedef void* (*fn_SDL_CreateTexture)(void*, uint32_t, int, int, int);
typedef int   (*fn_SDL_UpdateTexture)(void*, const void*, const void*, int);
typedef int   (*fn_SDL_RenderClear)(void*);
typedef int   (*fn_SDL_RenderCopy)(void*, void*, const void*, const void*);
typedef void  (*fn_SDL_RenderPresent)(void*);
typedef void  (*fn_SDL_DestroyTexture)(void*);
typedef void  (*fn_SDL_DestroyRenderer)(void*);
typedef void  (*fn_SDL_DestroyWindow)(void*);
typedef void  (*fn_SDL_Quit)(void);
typedef const char* (*fn_SDL_GetError)(void);
typedef int   (*fn_SDL_PollEvent)(void*);

typedef struct { uint32_t type; uint8_t padding[52]; } my_sdl_event_t;

static struct {
    fn_SDL_Init             Init;
    fn_SDL_CreateWindow     CreateWindow;
    fn_SDL_CreateRenderer   CreateRenderer;
    fn_SDL_CreateTexture    CreateTexture;
    fn_SDL_UpdateTexture    UpdateTexture;
    fn_SDL_RenderClear      RenderClear;
    fn_SDL_RenderCopy       RenderCopy;
    fn_SDL_RenderPresent    RenderPresent;
    fn_SDL_DestroyTexture   DestroyTexture;
    fn_SDL_DestroyRenderer  DestroyRenderer;
    fn_SDL_DestroyWindow    DestroyWindow;
    fn_SDL_Quit             Quit;
    fn_SDL_GetError         GetError;
    fn_SDL_PollEvent        PollEvent;
} S;

static int load_sdl2(void **lib_handle)
{
    const char *names[] = {
        "libSDL2-2.0.so.0",
        "libSDL2-2.0.so",
        "libSDL2.so",
        NULL
    };

    void *lib = NULL;
    for (int i = 0; names[i]; i++) {
        lib = dlopen(names[i], RTLD_NOW);
        if (lib) break;
    }
    if (!lib) {
        fprintf(stderr, "[DISPLAY] dlopen SDL2 failed: %s\n", dlerror());
        return -1;
    }

    #define LOAD(name) do { \
        S.name = (fn_SDL_##name)dlsym(lib, "SDL_" #name); \
        if (!S.name) { \
            fprintf(stderr, "[DISPLAY] dlsym SDL_%s failed\n", #name); \
            dlclose(lib); return -1; \
        } \
    } while(0)

    LOAD(Init);
    LOAD(CreateWindow);
    LOAD(CreateRenderer);
    LOAD(CreateTexture);
    LOAD(UpdateTexture);
    LOAD(RenderClear);
    LOAD(RenderCopy);
    LOAD(RenderPresent);
    LOAD(DestroyTexture);
    LOAD(DestroyRenderer);
    LOAD(DestroyWindow);
    LOAD(Quit);
    LOAD(GetError);
    LOAD(PollEvent);

    #undef LOAD

    *lib_handle = lib;
    printf("[DISPLAY] SDL2 loaded via dlopen\n");
    return 0;
}

int display_init(display_ctx_t *dctx, uint32_t frame_w, uint32_t frame_h)
{
    memset(dctx, 0, sizeof(*dctx));

    if (load_sdl2(&dctx->sdl_lib) < 0) {
        fprintf(stderr, "[DISPLAY] SDL2 not available, will save PPM instead\n");
        return -1;
    }

    if (S.Init(MY_SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "[DISPLAY] SDL_Init failed: %s\n", S.GetError());
        dlclose(dctx->sdl_lib);
        dctx->sdl_lib = NULL;
        return -1;
    }

    dctx->window = S.CreateWindow("PCIe DMA Frame",
                                   MY_SDL_WINDOWPOS_UNDEFINED,
                                   MY_SDL_WINDOWPOS_UNDEFINED,
                                   frame_w, frame_h,
                                   MY_SDL_WINDOW_SHOWN);
    if (!dctx->window) {
        fprintf(stderr, "[DISPLAY] CreateWindow failed: %s\n", S.GetError());
        S.Quit();
        dlclose(dctx->sdl_lib);
        dctx->sdl_lib = NULL;
        return -1;
    }

    uint32_t rflags = MY_SDL_RENDERER_ACCELERATED;
#if DISPLAY_USE_VSYNC
    rflags |= MY_SDL_RENDERER_PRESENTVSYNC;
#endif
    dctx->renderer = S.CreateRenderer(dctx->window, -1, rflags);
    if (!dctx->renderer) {
        // 拿不到加速渲染器：退回默认(可能是软件渲染，会明显更慢)
        dctx->renderer = S.CreateRenderer(dctx->window, -1, 0);
        fprintf(stderr, "[DISPLAY] 警告: 未获得 ACCELERATED 渲染器，可能在用软件渲染(慢)\n");
    }
    if (!dctx->renderer) {
        fprintf(stderr, "[DISPLAY] CreateRenderer failed: %s\n", S.GetError());
        S.DestroyWindow(dctx->window);
        S.Quit();
        dlclose(dctx->sdl_lib);
        dctx->sdl_lib = NULL;
        return -1;
    }

    // 原始代码: MY_SDL_PIXELFORMAT_ARGB8888
    //++ [改动] 使用 RGB565 匹配 FPGA 16-bit FIFO 输出
    dctx->texture = S.CreateTexture(dctx->renderer,
                                     MY_SDL_PIXELFORMAT_RGB565,
                                     MY_SDL_TEXTUREACCESS_STREAMING,
                                     frame_w, frame_h);
    //-- [改动] 结束
    if (!dctx->texture) {
        fprintf(stderr, "[DISPLAY] CreateTexture failed: %s\n", S.GetError());
        S.DestroyRenderer(dctx->renderer);
        S.DestroyWindow(dctx->window);
        S.Quit();
        dlclose(dctx->sdl_lib);
        dctx->sdl_lib = NULL;
        return -1;
    }

    dctx->tex_w = frame_w;
    dctx->tex_h = frame_h;
    dctx->sdl_ok = 1;

    // 原始代码: printf("[DISPLAY] SDL2 window: %ux%u ARGB8888\n", ...);
    printf("[DISPLAY] SDL2 window: %ux%u RGB565\n", frame_w, frame_h);
    return 0;
}

void display_show_frame(display_ctx_t *dctx, const uint8_t *frame_data,
                        uint32_t frame_w, uint32_t frame_h, uint32_t actual_w)
{
    (void)frame_h;
    if (!dctx->sdl_ok || !dctx->texture) return;

    // pitch = 源数据每行字节数（actual_w可能 > frame_w，用于修正HDMI行宽偏差）
    int pitch = (actual_w > 0 ? actual_w : frame_w) * 2;
    S.UpdateTexture(dctx->texture, NULL, frame_data, pitch);
    S.RenderClear(dctx->renderer);
    S.RenderCopy(dctx->renderer, dctx->texture, NULL, NULL);
    S.RenderPresent(dctx->renderer);
}

int display_poll_quit(display_ctx_t *dctx)
{
    if (!dctx->sdl_ok) return 0;

    my_sdl_event_t ev;
    while (S.PollEvent(&ev)) {
        if (ev.type == MY_SDL_QUIT_EVENT)
            return 1;
    }
    return 0;
}

void display_cleanup(display_ctx_t *dctx)
{
    if (dctx->sdl_ok) {
        if (dctx->texture)  S.DestroyTexture(dctx->texture);
        if (dctx->renderer) S.DestroyRenderer(dctx->renderer);
        if (dctx->window)   S.DestroyWindow(dctx->window);
        S.Quit();
    }
    if (dctx->sdl_lib) {
        dlclose(dctx->sdl_lib);
        dctx->sdl_lib = NULL;
    }
    dctx->sdl_ok = 0;
}

// ==================== PPM 保存（无依赖） ====================
int save_ppm(const char *filename, const uint8_t *data,
              uint32_t w, uint32_t h, uint32_t actual_w)
{
    FILE *f = fopen(filename, "wb");
    if (!f) {
        perror("[DISPLAY] save_ppm fopen");
        return -1;
    }

    fprintf(f, "P6\n%u %u\n255\n", w, h);

    uint32_t src_w = (actual_w > 0) ? actual_w : w;

    //++ [改动] RGB565 → RGB888 转换，按 actual_w 行宽读取
    for (uint32_t y = 0; y < h; y++) {
        const uint16_t *row = (const uint16_t *)(data + y * src_w * 2);
        for (uint32_t x = 0; x < w; x++) {
            uint16_t p = row[x];
            uint8_t rgb[3] = {
                ((p >> 11) & 0x1F) * 255 / 31,
                ((p >>  5) & 0x3F) * 255 / 63,
                ( p        & 0x1F) * 255 / 31
            };
            if(fwrite(rgb,1,3,f)!=3){int saved=errno;fclose(f);errno=saved;return -1;}
        }
    }
    //-- [改动] 结束

    if(fclose(f))return -1;
    printf("[DISPLAY] Saved %ux%u PPM to %s\n", w, h, filename);
    return 0;
}
