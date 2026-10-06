volatile int  gvar = 0x1234;
volatile int  idx  = 0;
const char    msg[] = "RISC-V";

int main(void)
{
    int ok = 1;
    if (gvar       != 0x1234) ok = 0;
    if (msg[idx+1] != 'I')    ok = 0;   /* msg[1] == 'I'，但 idx 是 volatile → 运行时才索引 */
    return ok;
}
