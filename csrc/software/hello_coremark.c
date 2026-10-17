#define PUTCHAR (*(volatile unsigned int *)0x00030008)

int main(void)
{
    const char *s = "Hello CoreMark!\n";

    while (*s != '\0') {
        PUTCHAR = (unsigned char)*s;
        s++;
    }

    return 1;
}

