// Basys3 demo: the switches choose n, the 7-segment display shows fib(n) in hex,
// and the LEDs show a running counter. It never returns.
#include "../mmio.h"

static unsigned int fib(unsigned int n)
{
    unsigned int a = 0, b = 1;
    while (n--) {
        unsigned int t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int main(void)
{
    unsigned int count = 0;
    for (;;) {
        unsigned int n = MMIO_SW & 0x1f;     // SW[4:0], fib(24) = 0xB520 still fits in 4 digits
        MMIO_SEG = fib(n) & 0xffff;
        MMIO_LED = (count++ >> 12) & 0xffff;
    }
}
