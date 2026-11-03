#ifndef IMAGE_INPUT_H
#define IMAGE_INPUT_H
#include <stdint.h>
typedef struct {char **paths;unsigned count;} image_list;
int image_list_open(image_list *list,const char *path);
void image_list_close(image_list *list);
/* Caller frees the returned row-major 384x216 RGB888 buffer. */
uint8_t *image_load_384(const char *path);
#endif
