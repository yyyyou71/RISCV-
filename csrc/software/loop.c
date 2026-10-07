volatile int i = 0;

int main(void)
{
    int limit = 3;
    while (i < limit) {
        i++;              /* 如果这一句丢了 → 死循环 */
    }
    return 1;
}
