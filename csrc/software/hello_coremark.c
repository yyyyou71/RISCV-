#define PUTCHAR (*(volatile unsigned int *)0x00030008)
#define CYCLE_COUNT (*(volatile unsigned int *)0x0003000c)
#define PRINT (*(volatile unsigned int *)0x00030004)

int main(void)
{
    const char *s = "Hello CoreMark!\n";

    while (*s != '\0') {
        PUTCHAR = (unsigned char)*s;
        s++;
    }

    PRINT = CYCLE_COUNT;
    return 1;
}

