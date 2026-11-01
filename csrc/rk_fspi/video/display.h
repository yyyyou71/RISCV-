/*
 * 显示模块 - dlopen 加载 SDL2，无需 libsdl2-dev
 * 回退: 保存为 PPM 图片文件
 */

#ifndef DISPLAY_H
#define DISPLAY_H

#include <stdint.h>

typedef struct {
    // —— SDL2 后端字段（display.c 使用）——
    void *sdl_lib;          // dlopen handle
    void *window;           // SDL_Window*
    void *renderer;         // SDL_Renderer*
    void *texture;          // SDL_Texture*
    uint32_t tex_w;
    uint32_t tex_h;
    int  sdl_ok;            // SDL2 加载成功标志

    // —— DRM dumb buffer 后端字段（display_drm.c 使用）——
    int      drm_fd;         // /dev/dri/cardX
    uint32_t conn_id;        // 连接器 ID
    uint32_t crtc_id;        // CRTC ID
    void    *saved_crtc;     // drmModeCrtc* 原始 CRTC，退出时恢复
    void    *mode_copy;      // drmModeModeInfo* 拷贝，供 SetCrtc 与退出用
    uint32_t fb_id[2];       // 双缓冲 framebuffer ID
    uint32_t dumb_handle[2]; // 双缓冲 dumb buffer handle
    uint8_t *map[2];         // 双缓冲 mmap 显存
    uint32_t map_size;       // 单块 mmap 长度
    uint32_t pitch;          // dumb buffer 每行字节
    uint32_t mode_w;         // 实际显示模式宽
    uint32_t mode_h;         // 实际显示模式高
    int      drm_bpp;        // 16=RGB565 直拷 / 32=XRGB8888 需转换
    int      cur_buf;        // 当前正在扫描输出的缓冲索引 (0/1)
    volatile int flip_pending; // page flip 是否在等 vblank 完成
    int      no_flip;        // 1=驱动不支持 page flip，退回 SetCrtc 翻页
    int      drm_ok;         // DRM 初始化成功标志
} display_ctx_t;

int  display_init(display_ctx_t *dctx, uint32_t frame_w, uint32_t frame_h);
void display_show_frame(display_ctx_t *dctx, const uint8_t *frame_data,
                        uint32_t frame_w, uint32_t frame_h, uint32_t actual_w);
void display_cleanup(display_ctx_t *dctx);

// 检查 SDL2 窗口关闭事件，返回 1 表示用户点了关闭
int  display_poll_quit(display_ctx_t *dctx);

// PPM 保存（始终可用）
int save_ppm(const char *filename, const uint8_t *data,
              uint32_t w, uint32_t h, uint32_t actual_w);

#endif /* DISPLAY_H */
